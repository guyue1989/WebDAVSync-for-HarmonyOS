import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { ServiceContainer } from '../application/ServiceContainer';
import { SyncTask } from '../domain/SyncTask';
import { SyncDirection } from '../domain/Enums';
import { ConflictStrategy } from '../domain/Enums';
import { Theme } from '../application/Theme';


@Entry
@Component
struct SyncSettingsPage {
  @State tasks: SyncTask[] = [];
  @State remoteDir: string = '';
  @State localDir: string = '';
  @State syncDirection: SyncDirection = SyncDirection.Bidirectional;
  @State conflictStrategy: ConflictStrategy = ConflictStrategy.CreateCopy;
  @State watchEnabled: boolean = true;
  @State filterRules: string = '';
  @State concurrency: number = 2;
  @State pollIntervalSec: number = 30;
  @State showPollHelp: boolean = false;
  @State showForm: boolean = false;
  @State editingTaskId: string = '';
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('systemDark') systemDark: boolean = false;

  private isDark(): boolean {
    return this.themeMode === 'dark' || (this.themeMode === 'system' && this.systemDark);
  }

  @State private hovBtn: string = '';
  @State private hovRow: string = '';

  async aboutToAppear(): Promise<void> {
    await ServiceContainer.init();
    await this.load();
  }

  // The folder this device picked last, '' for a user who has never picked one.
  private rememberedLocalDir(): string {
    const d = AppStorage.get<string>('selectedLocalDir');
    return d !== undefined ? d : '';
  }

  onPageShow(): void {
    const d = AppStorage.get<string>('selectedRemoteDir');
    if (d !== undefined && d !== '') {
      this.remoteDir = d;
    }
    // The folder just confirmed on the picker page wins outright: it has to land even in a form
    // that already held a different folder, so it is handed over once and then cleared.
    const pending = AppStorage.get<string>('pendingLocalDir');
    if (pending !== undefined && pending !== '') {
      this.localDir = pending;
      AppStorage.setOrCreate('pendingLocalDir', '');
      return;
    }
    // Otherwise offer the remembered folder, but only into an empty new-task form — an edit in
    // progress must keep the folder the task itself was saved with.
    if (this.localDir === '' && this.editingTaskId === '') {
      this.localDir = this.rememberedLocalDir();
    }
  }

  selectLocalDir(): void {
    router.pushUrl({ url: 'pages/LocalDirPickerPage' });
  }

  // Pickers return file://docs URIs whose non-ASCII names are percent-encoded; show the decoded
  // plain path instead, which is what fs actually uses and what a user can read.
  private showDir(dir: string): string {
    return ServiceContainer.localFileService.toPath(dir);
  }

  async load(): Promise<void> {
    const res = await ServiceContainer.taskManager.list();
    if (res.success && res.data !== null) {
      this.tasks = res.data;
    }
  }

  directionLabel(d: SyncDirection): string {
    if (d === SyncDirection.Bidirectional) { return '双向'; }
    if (d === SyncDirection.UploadOnly) { return '仅上传'; }
    return '仅下载';
  }

  strategyLabel(s: ConflictStrategy): string {
    if (s === ConflictStrategy.KeepLocal) { return '保留本地'; }
    if (s === ConflictStrategy.KeepRemote) { return '保留远端'; }
    if (s === ConflictStrategy.CreateCopy) { return '生成副本'; }
    return '人工选择';
  }

  async createTask(): Promise<void> {
    if (this.remoteDir === '' || this.localDir === '') {
      promptAction.showToast({ message: '请填写目录' });
      return;
    }
    const active = await ServiceContainer.connectionManager.getActive();
    if (!active.success || active.data === null) {
      promptAction.showToast({ message: '请先配置并激活连接' });
      return;
    }
    const task = new SyncTask();
    if (this.editingTaskId !== '') {
      task.id = this.editingTaskId;
    }
    task.connectionId = active.data.id;
    task.localDir = this.localDir;
    task.remoteDir = this.remoteDir;
    task.direction = this.syncDirection;
    task.conflictStrategy = this.conflictStrategy;
    task.watchEnabled = this.watchEnabled;
    task.filterRules = this.filterRules;
    task.concurrency = this.concurrency;
    task.pollIntervalSec = this.pollIntervalSec;
    const res = await ServiceContainer.taskManager.save(task);
    if (res.success) {
      // The scheduler keeps the task object it was started with, so a saved change to the
      // poll period or the local folder only takes effect after restarting that task.
      await ServiceContainer.syncScheduler.stopWatch(task.id);
      await ServiceContainer.syncScheduler.stopPolling(task.id);
      await ServiceContainer.syncScheduler.startWatch(task);
      await ServiceContainer.syncScheduler.startPolling(task);
      this.remoteDir = '';
      this.editingTaskId = '';
      this.showForm = false;
      await this.load();
      promptAction.showToast({ message: '任务已保存' });
    }
  }

  startEdit(task: SyncTask): void {
    this.editingTaskId = task.id;
    this.remoteDir = task.remoteDir;
    this.localDir = task.localDir;
    this.syncDirection = task.direction;
    this.conflictStrategy = task.conflictStrategy;
    this.watchEnabled = task.watchEnabled;
    this.filterRules = task.filterRules;
    this.concurrency = task.concurrency;
    this.pollIntervalSec = task.pollIntervalSec;
    this.showForm = true;
  }

  resetForm(): void {
    this.editingTaskId = '';
    this.remoteDir = '';
    this.localDir = this.rememberedLocalDir();
    this.syncDirection = SyncDirection.Bidirectional;
    this.conflictStrategy = ConflictStrategy.CreateCopy;
    this.watchEnabled = true;
    this.filterRules = '';
    this.concurrency = 2;
    this.pollIntervalSec = 30;
  }

  async runSync(task: SyncTask): Promise<void> {
    promptAction.showToast({ message: '开始同步...' });
    try {
      const result = await ServiceContainer.syncEngine.startSync(task);
      promptAction.showToast({ message: result.message });
    } catch (e) {
      promptAction.showToast({ message: '同步失败，请查看日志' });
    }
  }

  async startTask(task: SyncTask): Promise<void> {
    await ServiceContainer.syncScheduler.startWatch(task);
    await ServiceContainer.syncScheduler.startPolling(task);
    promptAction.showToast({ message: '静默同步已启动' });
  }

  async deleteTask(id: string): Promise<void> {
    await ServiceContainer.syncScheduler.stopWatch(id);
    await ServiceContainer.syncScheduler.stopPolling(id);
    await ServiceContainer.taskManager.remove(id);
    await this.load();
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(14).opacity(this.hovBtn === 'back' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'back' : ''; })
          .onClick(() => { router.back(); })
        Text('同步设置').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark())).margin({ left: 8 })
        Blank()
        if (this.showForm) {
          Button(this.editingTaskId !== '' ? '保存修改' : '保存任务').fontSize(13).opacity(this.hovBtn === 'save' ? 0.85 : 1)
            .onHover((h: boolean) => { this.hovBtn = h ? 'save' : ''; })
            .onClick(() => { this.createTask(); })
        }
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          ForEach(this.tasks, (task: SyncTask) => {
            Column() {
              Text(this.directionLabel(task.direction) + '：' + this.showDir(task.localDir) + ' ↔ ' + task.remoteDir).fontSize(14).fontColor(Theme.fg(this.isDark())).width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                Button('编辑').fontSize(12).height(32).margin({ top: 8, right: 8 }).opacity(this.hovBtn === 'edit-' + task.id ? 0.85 : 1)
                  .onHover((h: boolean) => { this.hovBtn = h ? 'edit-' + task.id : ''; })
                  .onClick(() => { this.startEdit(task); })
                Button('同步').fontSize(12).height(32).margin({ top: 8, right: 8 }).opacity(this.hovBtn === 'sync-' + task.id ? 0.85 : 1)
                  .onHover((h: boolean) => { this.hovBtn = h ? 'sync-' + task.id : ''; })
                  .onClick(() => { this.runSync(task); })
                Button('启动').fontSize(12).height(32).margin({ top: 8, right: 8 }).opacity(this.hovBtn === 'start-' + task.id ? 0.85 : 1)
                  .onHover((h: boolean) => { this.hovBtn = h ? 'start-' + task.id : ''; })
                  .onClick(() => { this.startTask(task); })
                Button('删除').fontSize(12).height(32).margin({ top: 8, right: 8 }).opacity(this.hovBtn === 'del-' + task.id ? 0.85 : 1)
                  .onHover((h: boolean) => { this.hovBtn = h ? 'del-' + task.id : ''; })
                  .onClick(() => { this.deleteTask(task.id); })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(12)
            .backgroundColor(this.hovRow === task.id ? Theme.cardHover(this.isDark()) : Color.Transparent)
            .onHover((h: boolean) => { this.hovRow = h ? task.id : ''; })
          }, (task: SyncTask) => task.id)

      if (this.showForm) {
          Column() {
            Row() {
              Text(this.remoteDir === '' ? '远程目录：未选择' : '远程目录：' + this.remoteDir)
              .fontSize(14)
              .fontColor(this.remoteDir === '' ? Theme.sub(this.isDark()) : Theme.fg(this.isDark()))
              .layoutWeight(1)
            Button('浏览选择').fontSize(13).opacity(this.hovBtn === 'browse-remote' ? 0.85 : 1)
              .onHover((h: boolean) => { this.hovBtn = h ? 'browse-remote' : ''; })
              .onClick(() => {
              router.pushUrl({ url: 'pages/FileBrowserPage', params: { mode: 'select' } });
            })
          }
          .width('100%')
          .constraintSize({ minHeight: 40 })
          .margin({ bottom: 8 })
          Row() {
            Text(this.localDir === '' ? '本地目录：未选择' : '本地目录：' + this.showDir(this.localDir))
              .fontSize(14)
              .fontColor(this.localDir === '' ? Theme.sub(this.isDark()) : Theme.fg(this.isDark()))
              .layoutWeight(1)
            Button('浏览选择').fontSize(13).opacity(this.hovBtn === 'browse-local' ? 0.85 : 1)
              .onHover((h: boolean) => { this.hovBtn = h ? 'browse-local' : ''; })
              .onClick(() => {
              this.selectLocalDir();
            })
          }
          .width('100%')
          .constraintSize({ minHeight: 40 })
          .margin({ bottom: 8 })
          Row() {
            Text('方向：' + this.directionLabel(this.syncDirection)).fontSize(14).fontColor(Theme.fg(this.isDark())).layoutWeight(1)
            Button('切换').fontSize(12).opacity(this.hovBtn === 'direction' ? 0.85 : 1)
              .onHover((h: boolean) => { this.hovBtn = h ? 'direction' : ''; })
              .onClick(() => {
              this.syncDirection = this.syncDirection === SyncDirection.Bidirectional ? SyncDirection.UploadOnly :
                (this.syncDirection === SyncDirection.UploadOnly ? SyncDirection.DownloadOnly : SyncDirection.Bidirectional);
            })
          }
          .width('100%')
          .margin({ bottom: 8 })
          Row() {
            Text('冲突：' + this.strategyLabel(this.conflictStrategy)).fontSize(14).fontColor(Theme.fg(this.isDark())).layoutWeight(1)
            Button('切换').fontSize(12).opacity(this.hovBtn === 'conflict' ? 0.85 : 1)
              .onHover((h: boolean) => { this.hovBtn = h ? 'conflict' : ''; })
              .onClick(() => {
              this.conflictStrategy = this.conflictStrategy === ConflictStrategy.CreateCopy ? ConflictStrategy.KeepLocal :
                (this.conflictStrategy === ConflictStrategy.KeepLocal ? ConflictStrategy.KeepRemote :
                  (this.conflictStrategy === ConflictStrategy.KeepRemote ? ConflictStrategy.ManualResolve : ConflictStrategy.CreateCopy));
            })
          }
          .width('100%')
          .margin({ bottom: 8 })
          Row() {
            Text('静默监测').fontSize(14).fontColor(Theme.fg(this.isDark()))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.watchEnabled }).onChange((on: boolean) => { this.watchEnabled = on; })
          }
          .width('100%')
          .margin({ bottom: 8 })
          Column() {
            Text('过滤规则').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
            TextInput({ placeholder: '*.tmp, *.log, .DS_Store（选填，逗号分隔）', text: this.filterRules })
              .onChange((v: string) => { this.filterRules = v; })
              .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark()))
              .width('100%')
              .height(44)
              .margin({ bottom: 4 })
            Text('示例：*.tmp, *.log, *.bak, Thumbs.db（匹配文件名/目录名，命中则跳过）').fontSize(12).fontColor(Theme.sub(this.isDark())).width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ bottom: 8 })
          Row() {
            Text('并发线程数：' + this.concurrency.toString()).fontSize(14).fontColor(Theme.fg(this.isDark())).layoutWeight(1)
            Button('-').fontSize(14).width(36).height(36).opacity(this.hovBtn === 'minus' ? 0.85 : 1)
              .onHover((h: boolean) => { this.hovBtn = h ? 'minus' : ''; })
              .onClick(() => {
              if (this.concurrency > 1) { this.concurrency -= 1; }
            })
            Button('+').fontSize(14).width(36).height(36).margin({ left: 8 }).opacity(this.hovBtn === 'plus' ? 0.85 : 1)
              .onHover((h: boolean) => { this.hovBtn = h ? 'plus' : ''; })
              .onClick(() => {
              if (this.concurrency < 10) { this.concurrency += 1; }
            })
          }
          .width('100%')
          .margin({ bottom: 8 })
          Column() {
            Row() {
              Text('轮询周期（秒）').fontSize(14).fontColor(Theme.fg(this.isDark()))
              Text('!')
                .fontSize(12)
                .fontColor(Theme.sub(this.isDark()))
                .width(18)
                .height(18)
                .textAlign(TextAlign.Center)
                .border({ width: 1, color: Theme.sub(this.isDark()), radius: 9 })
                .margin({ left: 6 })
                .bindPopup(this.showPollHelp, {
                  message: '远端轮询周期：每隔多少秒主动检测一次 NAS 端变化，检测到增删改才同步。值越小发现越快，但每次轮询都要遍历本地目录并对 NAS 的每个目录发一次 PROPFIND，太频繁会很耗电。范围 30~3600 秒。'
                })
                .opacity(this.hovBtn === 'help' ? 0.85 : 1)
                .onHover((h: boolean) => { this.hovBtn = h ? 'help' : ''; })
                .onClick(() => { this.showPollHelp = !this.showPollHelp; })
              Blank()
              Button('恢复默认').fontSize(12).opacity(this.hovBtn === 'reset-poll' ? 0.85 : 1)
                .onHover((h: boolean) => { this.hovBtn = h ? 'reset-poll' : ''; })
                .onClick(() => { this.pollIntervalSec = 30; })
            }
            .width('100%')
            .margin({ bottom: 4 })
            TextInput({ placeholder: '30', text: this.pollIntervalSec.toString() })
              .onChange((v: string) => {
                const n = Number(v);
                if (!Number.isNaN(n) && n >= 30 && n <= 3600) {
                  this.pollIntervalSec = Math.floor(n);
                }
              })
              .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark()))
              .width('100%')
              .height(44)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ bottom: 8 })
          }
          .width('100%')
          .padding(16)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .width('100%')
      .scrollBar(BarState.Auto)

      Button(this.showForm ? '收起' : '新增同步任务').width('90%').margin({ bottom: 16 }).opacity(this.hovBtn === 'toggle-form' ? 0.85 : 1)
        .onHover((h: boolean) => { this.hovBtn = h ? 'toggle-form' : ''; })
        .onClick(() => {
        if (this.showForm) {
          this.showForm = false;
          this.editingTaskId = '';
        } else {
          this.resetForm();
          this.showForm = true;
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }
}