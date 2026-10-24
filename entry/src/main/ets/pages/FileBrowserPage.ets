import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';

import { ServiceContainer } from '../application/ServiceContainer';
import { AppContext } from '../application/AppContext';
import { SettingsStore } from '../application/SettingsStore';
import { FileEntry } from '../domain/FileEntry';
import { Connection } from '../domain/Connection';
import { Theme } from '../application/Theme';

@Entry
@Component
struct FileBrowserPage {
  @State currentPath: string = '/';
  @State entries: FileEntry[] = [];
  @State newDirName: string = '';
  @State isSelectMode: boolean = false;
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('systemDark') systemDark: boolean = false;
  private conn: Connection | null = null;
  private lastEnterTime: number = 0;

  private isDark(): boolean {
    return this.themeMode === 'dark' || (this.themeMode === 'system' && this.systemDark);
  }

  @State private hovBtn: string = '';
  @State private hovRow: string = '';

  async aboutToAppear(): Promise<void> {
    await ServiceContainer.init();
    const params = router.getParams() as Record<string, string>;
    if (params !== null && params !== undefined && params.mode === 'select') {
      this.isSelectMode = true;
    }
    const active = await ServiceContainer.connectionManager.getActive();
    if (active.success && active.data !== null) {
      this.conn = active.data;
      await this.refresh();
    } else {
      promptAction.showToast({ message: '请先在「连接管理」中配置并设为当前连接' });
    }
  }

  async refresh(): Promise<void> {
    if (this.conn === null) {
      promptAction.showToast({ message: '请先配置连接' });
      return;
    }
    const res = await ServiceContainer.webDavClient.listDirectory(this.conn, this.currentPath);
    if (res.success && res.data !== null) {
      this.entries = res.data;
    } else {
      promptAction.showToast({ message: '列目录失败' });
    }
  }

  enter(name: string): void {
    const now = Date.now();
    if (now - this.lastEnterTime < 500) {
      return;
    }
    this.lastEnterTime = now;
    const path = this.currentPath === '/' ? '/' + name : this.currentPath + '/' + name;
    this.currentPath = path;
    this.refresh();
  }

  goUp(): void {
    if (this.currentPath === '/') {
      return;
    }
    const idx = this.currentPath.lastIndexOf('/');
    this.currentPath = idx <= 0 ? '/' : this.currentPath.substring(0, idx);
    this.refresh();
  }

  selectRemoteDir(): void {
    AppStorage.setOrCreate('selectedRemoteDir', this.currentPath);
    SettingsStore.put('selectedRemoteDir', this.currentPath);
    router.back();
  }

  async download(entry: FileEntry): Promise<void> {
    if (this.conn === null) {
      return;
    }
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return;
    }
    const remoteRel = this.currentPath === '/' ? '/' + entry.name : this.currentPath + '/' + entry.name;
    const localDir = ctx.filesDir + '/downloads';
    const localPath = localDir + '/' + entry.name;
    const res = await ServiceContainer.webDavClient.downloadFile(this.conn, remoteRel, localPath, 0, () => {});
    promptAction.showToast({ message: res.success ? '下载完成' : '下载失败' });
  }

  async removeEntry(entry: FileEntry): Promise<void> {
    if (this.conn === null) {
      return;
    }
    const remoteRel = this.currentPath === '/' ? '/' + entry.name : this.currentPath + '/' + entry.name;
    const res = await ServiceContainer.webDavClient.deleteItem(this.conn, remoteRel);
    if (res.success) {
      await this.refresh();
    } else {
      promptAction.showToast({ message: '删除失败' });
    }
  }

  async createDir(): Promise<void> {
    if (this.conn === null || this.newDirName === '') {
      return;
    }
    const remoteRel = this.currentPath === '/' ? '/' + this.newDirName : this.currentPath + '/' + this.newDirName;
    const res = await ServiceContainer.webDavClient.mkdir(this.conn, remoteRel);
    if (res.success) {
      this.newDirName = '';
      await this.refresh();
    } else {
      promptAction.showToast({ message: '创建失败' });
    }
  }

  async upload(): Promise<void> {
    if (this.conn === null) {
      return;
    }
    try {
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select({ maxSelectNumber: 1 });
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const name = this.basename(uri);
      const remoteRel = this.currentPath === '/' ? '/' + name : this.currentPath + '/' + name;
      const res = await ServiceContainer.webDavClient.uploadFile(this.conn, uri, remoteRel, () => {});
      promptAction.showToast({ message: res.success ? '上传完成' : '上传失败' });
      await this.refresh();
    } catch (e) {
      promptAction.showToast({ message: '上传失败' });
    }
  }

  private basename(uri: string): string {
    const parts = uri.split('/');
    return decodeURIComponent(parts[parts.length - 1]);
  }

  build() {
    Column() {
      Row() {
        Button('‹ 主页').fontSize(14).opacity(this.hovBtn === 'back' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'back' : ''; })
          .onClick(() => { router.back(); })
        Button('上级').fontSize(14).margin({ left: 8 }).opacity(this.hovBtn === 'up' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'up' : ''; })
          .onClick(() => { this.goUp(); })
        Text(this.currentPath).fontSize(13).fontColor(Theme.sub(this.isDark())).margin({ left: 8 }).layoutWeight(1)
        Button('刷新').fontSize(14).opacity(this.hovBtn === 'refresh' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'refresh' : ''; })
          .onClick(() => { this.refresh(); })
      }
      .width('100%')
      .padding(12)

      Row() {
        TextInput({ placeholder: '新目录名', text: this.newDirName }).onChange((v: string) => { this.newDirName = v; })
          .layoutWeight(1).height(40)
        Button('新建目录').fontSize(13).margin({ left: 8 }).opacity(this.hovBtn === 'mkdir' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'mkdir' : ''; })
          .onClick(() => { this.createDir(); })
        Button('上传').fontSize(13).margin({ left: 8 }).opacity(this.hovBtn === 'upload' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'upload' : ''; })
          .onClick(() => { this.upload(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 12 })

      List() {
        ForEach(this.entries, (entry: FileEntry) => {
          ListItem() {
            Row() {
              Text(entry.isDirectory ? '📁 ' + entry.name : '📄 ' + entry.name).fontSize(15).fontColor(Theme.fg(this.isDark())).layoutWeight(1)
              if (!entry.isDirectory) {
                Button('下载').fontSize(12).height(30).opacity(this.hovBtn === 'dl-' + entry.name ? 0.85 : 1)
                  .onHover((h: boolean) => { this.hovBtn = h ? 'dl-' + entry.name : ''; })
                  .onClick(() => { this.download(entry); })
              }
              Button('删除').fontSize(12).height(30).margin({ left: 8 }).opacity(this.hovBtn === 'del-' + entry.name ? 0.85 : 1)
                .onHover((h: boolean) => { this.hovBtn = h ? 'del-' + entry.name : ''; })
                .onClick(() => { this.removeEntry(entry); })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.hovRow === entry.name ? Theme.cardHover(this.isDark()) : Color.Transparent)
            .onHover((h: boolean) => { this.hovRow = h ? entry.name : ''; })
          }
          .onClick(() => {
            if (entry.isDirectory) {
              this.enter(entry.name);
            } else {
              this.download(entry);
            }
          })
        }, (entry: FileEntry) => this.currentPath + '/' + entry.name)
      }
      .layoutWeight(1)

      if (this.isSelectMode) {
        Column() {
          // The path used to be baked into the button label, where a Button never wraps: a narrow
          // window cut it off mid-string, right on the control that tells you what you are picking.
          Text('当前目录：' + this.currentPath)
            .fontSize(13)
            .fontColor(Theme.sub(this.isDark()))
            .width('100%')
            .margin({ bottom: 6 })
          Button('选择当前目录').width('100%').opacity(this.hovBtn === 'select' ? 0.85 : 1)
            .onHover((h: boolean) => { this.hovBtn = h ? 'select' : ''; })
            .onClick(() => {
            this.selectRemoteDir();
          })
        }
        .width('90%')
        .margin({ bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }
}