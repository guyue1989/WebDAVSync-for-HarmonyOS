# 年槌糕同步

HarmonyOS NEXT（SDK 6.1.0(23) / API 23）上的 WebDAV 文件同步工具，面向 Synology NAS 等 WebDAV 服务器，在本地目录与远程目录之间做双向或单向同步。在 PC/2in1 上它以状态栏托盘常驻，窗口关掉之后同步、监听和轮询照常运行。

**设备支持：只做 HarmonyOS PC / 2in1。** 直接原因是**开发者手上没有鸿蒙手机和平板**，这两种形态一行代码都没在真机上跑过，所以不去声明一个自己无法验证的适用范围（`module.json5` 的 `deviceTypes` 因此只写 `2in1`，手机上安装不到）。需要说清的是：手机侧缺的主要是**验证机会**，而不是被刻意砍掉的功能分支——代码里对 `hideAbility()` 返回 801、`addToStatusBar` 抛错都做了失败回退；但常驻这套核心能力（状态栏托盘、窗口隐藏后继续同步、长时任务保活）本身依赖桌面形态，手机上即使装上了也复现不出「窗口关掉后照常同步」这句承诺，与其让用户搜到后踩坑，不如先不声明。将来若有真机或远程真机跑通，再放开设备范围。

## 功能特性

- **连接管理** — 可配置多个 WebDAV 服务器，LAN/WAN 双地址自动探测，凭证以 AES-256-CBC 加密存储
- **多同步任务** — 每个任务是「本地目录 ↔ 远程目录」一条映射，可独立启停
- **同步方向** — 双向同步、仅上传、仅下载
- **冲突处理** — 保留本地 / 保留远程 / 生成副本 / 手动处理
- **变更检测** — 本地用 mtime+size，远端用 etag（同一轮扫描内建立基线，不写回本地 mtime）；目录按存在性加基线判定，远端被删的目录本地才删
- **本地实时监听** — 目录扫描轮询，安静时 1 s 一次，60 s 内无变更自动退到 15 s；500 ms 防抖；自己写入的文件会从变更集里扣掉，不会自激
- **远端定时轮询** — 周期按任务配置，下限 30 s（一轮要走完整个本地树，再快就是白耗资源）
- **断点续传** — 下载按 Range 4 MB 分块拼接、原子落盘；进度逐文件持久化，暂停或进程被杀后按剩余清单继续
- **文件过滤** — 通配符规则（`*.tmp, *.log, Thumbs.db`），命中即跳过
- **并发传输** — 可配置并发数
- **超长文件名** — 本地拒绝超过 255 字节的单级名称，这类路径映射成确定性短名存放，原名仍是同步键
- **状态栏托盘（PC/2in1）** — 托盘图标、关闭按钮改为隐藏窗口、单击图标恢复主窗口、右键菜单
- **后台保活** — 长时任务（计算任务优先，数据传输兜底），窗口隐藏后同步不休眠
- **主题** — 浅色 / 深色 / 跟随系统，默认为跟随系统；用户手动选择后记住，启动窗口底色随明暗模式切换
- **目录授权** — 「本地目录」页有文档/下载/桌面/图片/视频/音乐六个快捷入口，点击直接拉起系统文件管理的授权界面，也可以浏览自选目录；本机会记住上一次选过的本地目录与远程目录，新任务表单只预填这个记忆，新用户进来是「未选择」状态，不会看到一个替他们选好的文件夹
- **桌面交互** — 布局跟随窗口宽度自适应（PC 自由窗口可任意缩放）：表单项贴顶排列、按钮条放不下就折行、长路径独占一行完整显示，鼠标悬停高亮

## 技术栈

| 项 | 说明 |
|---|---|
| 平台 | HarmonyOS NEXT，编译与最低 SDK 均为 6.1.0(23)（API 23） |
| 语言 | ArkTS（严格模式，禁 `any`/`unknown`） |
| 构建 | hvigor + DevEco Studio 5.0+ |
| 网络 | `@ohos.net.http`（PROPFIND / GET Range / PUT / MKCOL / DELETE） |
| 加密 | `@ohos.security.cryptoFramework`（AES-256-CBC-PKCS7） |
| 持久化 | `@ohos.data.preferences`（凭证、连接、任务、同步基线、应用设置） |
| 文件 | `@kit.CoreFileKit`：`fs` + `DocumentViewPicker`（FOLDER 模式）+ `fileShare` 持久授权 |
| 托盘 | `@kit.DeskTopExtensionKit`：`statusBarManager` + `StatusBarViewExtensionAbility` |
| 保活 | `backgroundTaskManager`（taskKeeping / dataTransfer） |
| 通知 | `@ohos.notificationManager` |
| 图标 | `@ohos.multimedia.image` 解码为 24vp PixelMap |

## 项目结构

```
AppScope/                        # 应用级配置
entry/src/main/module.json5      # singleton + backgroundModes + statusBarView 扩展 Ability
entry/src/main/ets/
├── application/                 # 应用服务层
│   ├── AppContext.ets           # 全局 Context 持有 + 托盘恢复主窗口的回调
│   ├── ServiceContainer.ets     # 依赖组装（手动 DI 容器）
│   ├── ConnectionManager.ets    # 连接 CRUD
│   ├── SyncEngine.ets           # 同步核心：快照对比 → 计划生成 → 执行 → 基线重建
│   ├── SyncScheduler.ets        # 本地监听 + 远端轮询调度
│   ├── TaskManager.ets          # 同步任务管理
│   ├── SyncProgressTracker.ets  # 进度追踪
│   ├── SettingsStore.ets        # 应用级键值设置
│   ├── StatusBarService.ets     # 托盘图标、左键通道、右键菜单
│   ├── TrayService.ets          # 托盘态的通知占位
│   ├── BackgroundTaskService.ets# 长时任务申请/复用/重申请
│   ├── UriPermission.ets        # 目录授权持久化与每次启动激活
│   ├── NotificationService.ets  # 同步结果通知
│   ├── Theme.ets / SystemTheme.ets  # 主题色与明暗模式落地
│   └── LogService.ets
├── domain/                      # 领域模型
│   ├── Connection.ets / SyncTask.ets
│   ├── FileEntry.ets / FileState.ets  # 文件条目 / 同步基线
│   ├── ChangeSet.ets / ChangeDetector.ets  # 变更检测
│   ├── SyncResult.ets / Conflict.ets
│   ├── FileFilter.ets           # 通配符过滤
│   ├── LongNameMapper.ets       # 超长路径名映射
│   ├── TransferCursor.ets
│   ├── Enums.ets / Result.ets
├── infrastructure/              # 基础设施（均按接口注入）
│   ├── WebDavClient.ets         # WebDAV 协议实现
│   ├── LocalFileService.ets     # 本地文件读写
│   ├── SyncStore.ets            # 同步状态与基线持久化
│   ├── SecureStore.ets          # 凭证加密存储
│   └── FileWatcher.ets          # 本地目录监听（含静默退避）
├── statusbar/                   # 托盘左键通道（独立进程）
│   ├── TrayPanelAbility.ets     # statusBarView 扩展 Ability，负责拉起主窗口
│   └── TrayRaise.ets            # 拉起入口
├── pages/                       # UI 页面
│   ├── Index.ets                # 主页：主题、关闭行为、各入口
│   ├── ConnectionListPage.ets / ConnectionEditPage.ets
│   ├── SyncSettingsPage.ets     # 同步任务列表与任务表单
│   ├── SyncStatusPage.ets       # 同步状态与进度
│   ├── FileBrowserPage.ets      # 远端文件浏览
│   ├── LocalDirPickerPage.ets   # 本地目录选择与授权
│   └── TrayPanelPage.ets        # 托盘面板占位页
└── entryability/
    └── EntryAbility.ets         # 入口：关闭即隐藏、托盘注册、恢复、保活
```

## 架构设计

分层架构 + 手动依赖注入：

- **domain** — 纯数据模型与业务规则，不依赖框架 API
- **infrastructure** — 文件系统、WebDAV 协议、持久化的具体实现，均定义接口（`IWebDavClient`、`ILocalFileService` 等）
- **application** — 业务编排层，`SyncEngine` 只通过接口调用基础设施，`ServiceContainer` 在启动时组装依赖图

同步引擎一轮的流程：

1. 扫描本地目录生成快照；递归 PROPFIND 生成远端快照。**PROPFIND 失败则整轮中止**——半途的列表和「NAS 把这一片删了」无法区分
2. 与上轮保存的 `FileState` 基线对比，`ChangeDetector` 判定本地/远端各自的变更
3. `computePlan` 生成计划：上传 / 下载 / 建目录 / 删除 / 冲突
4. 按依赖顺序执行：先建目录 → 再传文件 → 最后处理删除
5. 重建基线：只给两侧都存在的路径写基线，并清理已消失的路径；刚 PUT 完的 etag 不落基线，等下一轮扫描确认
6. 进度文案始终标明方向与原因（`上传 NAS n`、`下载到本地 n`、`本地已删，删 NAS n`、`NAS 已删，删本地 n`）

### 托盘与后台常驻

- `EntryAbility` 是 `singleton`。`windowStageClose` 被拦下后调用 `hideAbility()`：窗口和 Dock 图标消失，Ability 继续运行，托盘图标成为唯一入口（关闭行为可在主页关掉，此时改为正常退出/最小化）。
- 托盘图标由 `StatusBarService.add()` 通过 `statusBarManager.addToStatusBar()` 添加，图标必须解码成 24vp×24vp PixelMap，`quickOperation.height` 必须大于 0。
- **左键链路**：本设备从不投递 `statusBarIconClick` 事件，所以左键走 QuickOperation 面板 —— `TrayPanelAbility`（`StatusBarViewExtensionAbility`，独立进程）在 `onForeground` / 页面 `onPageShow` 时 `startAbility(EntryAbility)`，singleton 被重新拉起即恢复窗口。面板会话**不主动 `terminateSelf()`**：宿主会在约 100 ms 后重开一个会话，那张空面板会盖在刚恢复的窗口上，表现为「要点两次」。
- 窗口隐藏后进程会被挂起，所以 `onBackground` 申请长时任务（`taskKeeping` 优先，失败退到 `dataTransfer`；`9800005` 视为已持有），`onForeground` 释放；对应 module.json5 的 `backgroundModes` 与 `KEEP_BACKGROUND_RUNNING` 缺一不可。
- 手机/平板没有这些桌面能力：`hideAbility()` 返回 801，`addToStatusBar` 抛错，代码按失败回退到最小化。因为核心常驻形态在手机上不成立、且开发者没有鸿蒙手机/平板可以做真机验证（详见开头「设备支持」），`module.json5` 的 `deviceTypes` 只声明 `2in1`，手机上根本装不到；将来要覆盖手机，先用真机或远程真机跑一遍再放开设备范围（AGC 后台的「支持设备」勾选必须同步改，Profile 也要重新生成）。

## 构建与运行

1. 复制签名模板：`cp build-profile.json5.template build-profile.json5`
2. 把 `build-profile.json5` 中的占位值替换为实际签名证书路径与密码（该文件已在 `.gitignore` 中，绝不提交）
3. 用 DevEco Studio 5.0+ 打开项目根目录，等待 hvigor 同步依赖
4. 选择目标设备（只声明了 `2in1`，即 PC/2in1 真机或对应模拟器），点击 Run
5. 首次使用需在「本地目录」页重新选择同步目录并授权——授权是持久化的，但**重新构建/重装会清空**，必须重选

## 权限

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | WebDAV 网络通信 |
| `ohos.permission.GET_NETWORK_INFO` | 检测网络状态 |
| `ohos.permission.FILE_ACCESS_PERSIST` | 保存/恢复用户选定目录的访问授权 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 窗口隐藏后继续同步（需 `reason` + `usedScene`） |

目录授权通过 `DocumentViewPicker`（FOLDER 模式）取得，读写模式必须一起传 `READ_MODE | WRITE_MODE`（`WRITE_MODE` 不含读权限），并且在 `onSessionCreate` 当场持久化；每次启动都要 `activatePermission`，之后才能碰该目录。

选择器返回的是 `file://docs/storage/...` 形式的 URI，本项目的规则是**去掉 `file://docs` 前缀，再做一次 `decodeURIComponent`**，之后只按普通路径用 `fs`。漏了解码这一步，中文目录名会以 `%E7%A4%BA%E4%BE%8B...` 的编码拼写被拿去查找，`fs` 报 `No such file or directory`，症状和"授权丢了"完全一样、极难猜。这条转换只有一处实现——`LocalFileService.toPath()`（`ILocalFileService` 的接口方法），同步引擎取任务里的本地目录也走它，不允许再有第二处手写的前缀裁剪。

## 兼容性与已知平台行为

- 编译 SDK / 最低版本：6.1.0(23)，即 API 23；运行环境 HarmonyOS NEXT；设备类型仅 `2in1`（须与 AGC 后台「支持设备」一致）。这是**未实测所以不声明**，不是手机端适配被砍掉，理由见开头「设备支持」
- 托盘、`hideAbility`/`showAbility`（PC/2in1 13+）、`TASK_KEEPING`（PC/2in1 API 20/21 起对三方开放）只在桌面形态可用
- 本 SDK 中不存在或无效的东西，不要指望它们：`statusBarManager.isStatusBarCapabilitySupported`（API 26）、`backgroundTaskManager.on('continuousTaskCancel')`、`Window.setWindowCloseInterceptor`、`Window.setWindowIcon`、module.json5 的 `excludeFromDock`（官方标注「该标签配置不生效」）
- 图标用分层图标（`$media:layered_image`：前景 = 透明 glyph `foreground.png`，背景 = 纯色 `background.png`），`AppScope/app.json5` 与 `module.json5` 的 `abilities[].icon` 都指向它。两层均为 **1024×1024 PNG**，背景层是纯白且不含任何透明像素，前景图形只占画幅中心约 70%——这三条是应用市场「应用图标」的上架检查项，尺寸不对或背景留透明会直接被卡。窗口标题栏会把 Ability 图标原样画出来，所以深色标题栏上会有一块白底，这是同一份资源无法拆开的既有限制（本 SDK 没有按窗口设置图标的接口）。
- `store/app_icon_1024_flat.png`（33 KB，1024×1024，整张不透明）= 前景叠在纯白背景上的合成单图，只给 AGC 后台「应用图标」上传框用，不参与打包；Hap 里预置的仍是上面那两层分层资源。
- PC 的 `DocumentViewPicker` 会记住用户上次导航到的位置并优先用它，所以 `defaultFilePathUri`（API 10+）拿来做定位并不可靠。要"一键授权某个固定目录"得同时把 `authMode`（API 12+）置 true——拉起的是文件管理的授权界面而不是常规选择器，且官方`设备行为差异`明写**仅 2in1 生效**，此时 `defaultFilePathUri` 变必填、含义转为"待授权 URI"。`multiAuthMode` / `multiUriArray`（API 15+）是 Phone-only 且只支持文件，文件夹上不生效
- 快捷入口的目录名要按本机实际拼写取：`/storage/Users/currentUser/` 下是 `Desktop`、`Documents`、**`Download`（单数）**、**`Images`（不是 `Pictures`）**、`Music`、`Videos`。写成 `Downloads`/`Pictures` 得到的是「找不到或无法打开此路径」，那是路径不存在，不是授权被拒
- `menuCode` 需要 API 24+，右键菜单项只能按 `title` 识别；系统自带且无法抑制的「退出」项会出现在托盘右键菜单里

## 许可

[MIT](LICENSE) — Copyright (c) 2026 niangao。可自由使用、修改、再分发与商用，分发时保留版权声明与许可声明即可。
