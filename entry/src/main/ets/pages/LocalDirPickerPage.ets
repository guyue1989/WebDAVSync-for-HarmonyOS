
import { AppContext } from '../application/AppContext';
import { Theme } from '../application/Theme';
import { SettingsStore } from '../application/SettingsStore';
import { ServiceContainer } from '../application/ServiceContainer';
import { picker } from '@kit.CoreFileKit';
import { UriPermission } from '../application/UriPermission';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';

const USER_ROOT = '/storage/Users/currentUser';

interface QuickAccess {
  label: string;
  path: string;
}

@Entry
@Component
struct LocalDirPickerPage {
  @State selectedPath: string = '';
  @State permWarning: string = '';
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('systemDark') systemDark: boolean = false;

  private quickAccessList: QuickAccess[] = [
    { label: '文档', path: USER_ROOT + '/Documents' },
    // Device names, not the Android/mac habit: this PC has Download (singular) and Images, so
    // Downloads/Pictures made those two buttons fail with 找不到或无法打开此路径.
    { label: '下载', path: USER_ROOT + '/Download' },
    { label: '桌面', path: USER_ROOT + '/Desktop' },
    { label: '图片', path: USER_ROOT + '/Images' },
    { label: '视频', path: USER_ROOT + '/Videos' },
    { label: '音乐', path: USER_ROOT + '/Music' },
  ];

  private isDark(): boolean {
    return this.themeMode === 'dark' || (this.themeMode === 'system' && this.systemDark);
  }

  @State private hovBtn: string = '';

  private showToast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (e) {
    }
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (e) {
    }
  }

  async aboutToAppear(): Promise<void> {
    const saved = AppStorage.get<string>('selectedLocalDir');
    if (saved !== undefined && saved !== '') {
      this.selectedPath = saved;
      // A restored URI may belong to an expired picker session; verify it still lists.
      if (UriPermission.isUri(saved)) {
        try {
          await fs.listFile(ServiceContainer.localFileService.toPath(saved));
        } catch (e) {
          const err = e as Error;
          this.permWarning = '当前文件夹无法访问：' + err.message + '，请重新选择文件夹';
        }
      }
    }
  }

  // startUri is the folder the quick-access row asked for, or '' for the plain browse flow.
  private openFolderPicker(startUri: string): void {
    try {
      const context: common.UIAbilityContext | null = AppContext.getContext();
      if (context === null) {
        this.permWarning = '无法获取应用上下文';
        return;
      }

      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      if (startUri !== '') {
        // Quick access has to ask the system for a grant on that exact folder. A plain
        // defaultFilePathUri would only move the picker's start location, which 2in1 overrides
        // with its remembered position; authMode opens the file-manager grant sheet instead and
        // is documented as working on 2in1 (API 12+).
        options.defaultFilePathUri = startUri;
        options.authMode = true;
      }

      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      docPicker.select(options, async (err: Error, filePaths: Array<string>) => {
        if (err) {
          this.permWarning = '选择文件夹失败：' + err.message;
          return;
        }
        if (filePaths.length > 0) {
          this.selectedPath = filePaths[0];
          // The picker grant only lives as long as this session, so persist it here instead of
          // waiting for the confirm button; without it the folder is unreadable after a restart.
          const fail = await UriPermission.persist(this.selectedPath);
          this.permWarning = fail === '' ? '' : '权限持久化失败：' + fail + '，重启后需要重新选择文件夹';
        }
      });
    } catch (e) {
      const err = e as Error;
      this.permWarning = '打开文件夹选择器失败：' + err.message;
    }
  }

  selectFromQuickAccess(path: string): void {
    this.openFolderPicker('file://docs' + path);
  }

  selectCustomDir(): void {
    this.openFolderPicker('');
  }

  // The URI form is percent-encoded and carries the file://docs prefix, which reads as noise to
  // a user; show the plain path fs actually works with.
  private displayPath(): string {
    return ServiceContainer.localFileService.toPath(this.selectedPath);
  }

  async confirmSelection(): Promise<void> {
    if (this.selectedPath === '') {
      this.showToast('请先选择文件夹');
      return;
    }
    hilog.info(0x0000, 'WebDAVSync', 'confirmSelection: path=%{public}s', this.selectedPath);

    await SettingsStore.put('selectedLocalDir', this.selectedPath);
    AppStorage.setOrCreate('selectedLocalDir', this.selectedPath);
    AppStorage.setOrCreate('localDirUnusable', false);
    // Handed to the task form as a one-shot so it lands even when that form already held a
    // different folder; 'selectedLocalDir' above stays as the device's memory used to prefill an
    // empty new-task form.
    AppStorage.setOrCreate('pendingLocalDir', this.selectedPath);

    // Reinstalling clears the folder grant, so the watchers started at launch are dead in the
    // water. Restart them now that the permission is live, otherwise local changes only
    // surface on the slow remote poll.
    await ServiceContainer.restartWatchers();

    this.goBack();
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(14).opacity(this.hovBtn === 'back' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'back' : ''; })
          .onClick(() => { this.goBack(); })
        Text('本地目录').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark())).margin({ left: 8 })
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
      if (this.permWarning !== '') {
        Text(this.permWarning)
          .fontSize(13)
          .fontColor('#cc6600')
          .width('90%')
          .padding(10)
          .backgroundColor(this.isDark() ? '#332200' : '#fff3e0')
          .borderRadius(8)
          .margin({ left: 16, right: 16, bottom: 8 })
      }

      Text('选择同步文件夹').fontSize(15).fontColor(Theme.fg(this.isDark()))
        .width('90%').margin({ top: 8, bottom: 12 })

      Text('快捷访问：').fontSize(13).fontColor(Theme.sub(this.isDark()))
        .width('90%').margin({ bottom: 8 })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.quickAccessList, (item: QuickAccess) => {
          Button(item.label)
            .fontSize(13)
            .height(36)
            .backgroundColor(this.hovBtn === 'qa-' + item.path ? Theme.cardHover(this.isDark()) : Theme.card(this.isDark()))
            .fontColor(Theme.fg(this.isDark()))
            .margin({ right: 8, bottom: 8 })
            .onHover((h: boolean) => { this.hovBtn = h ? 'qa-' + item.path : ''; })
            .onClick(() => { this.selectFromQuickAccess(item.path); })
        }, (item: QuickAccess) => item.path)
      }
      .width('90%')
      .margin({ bottom: 16 })

      Button('浏览其他文件夹...')
        .fontSize(14)
        .width('90%')
        .backgroundColor(Theme.primary(this.isDark()))
        .fontColor('#ffffff')
        .margin({ bottom: 16 })
        .opacity(this.hovBtn === 'browse' ? 0.85 : 1)
        .onHover((h: boolean) => { this.hovBtn = h ? 'browse' : ''; })
        .onClick(() => { this.selectCustomDir(); })

      if (this.selectedPath !== '') {
        Column() {
          Text('已选择：').fontSize(13).fontColor(Theme.sub(this.isDark())).width('100%')
          Text(this.displayPath())
            .fontSize(14)
            .fontColor(Theme.fg(this.isDark()))
            .width('100%')
            .padding(12)
            .backgroundColor(Theme.card(this.isDark()))
            .borderRadius(8)
            .margin({ top: 4 })
        }
        .width('90%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 16 })
      }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .width('100%')

      Button('确认选择')
        .fontSize(16)
        .width('90%')
        .backgroundColor(this.selectedPath !== '' ? Theme.primary(this.isDark()) : Theme.card(this.isDark()))
        .fontColor(this.selectedPath !== '' ? '#ffffff' : Theme.sub(this.isDark()))
        .enabled(this.selectedPath !== '')
        .margin({ bottom: 16 })
        .opacity(this.hovBtn === 'confirm' ? 0.85 : 1)
        .onHover((h: boolean) => { this.hovBtn = h ? 'confirm' : ''; })
        .onClick(() => { this.confirmSelection(); })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }
}
