import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { ServiceContainer } from '../application/ServiceContainer';
import { Connection } from '../domain/Connection';
import { BusinessError } from '@ohos.base';
import { Theme } from '../application/Theme';

@Entry
@Component
struct ConnectionEditPage {
  @State connId: string = '';
  @State name: string = '';
  @State baseUrl: string = '';
  @State username: string = '';
  @State password: string = '';
  @State rootPath: string = '/';
  @State allowInsecure: boolean = false;
  @State lanUrl: string = '';
  @State wanUrl: string = '';
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('systemDark') systemDark: boolean = false;

  private isDark(): boolean {
    return this.themeMode === 'dark' || (this.themeMode === 'system' && this.systemDark);
  }

  @State private hovBtn: string = '';

  async aboutToAppear(): Promise<void> {
    const params = router.getParams() as Record<string, string>;
    await ServiceContainer.init();
    let editId: string = '';
    if (params !== null && params !== undefined && params['id'] !== undefined && params['id'] !== '') {
      editId = params['id'];
    }
    if (editId === '') {
      const appId = AppStorage.get<string>('editingConnId');
      if (appId !== undefined && appId !== '') {
        editId = appId;
      }
    }
    if (editId !== '') {
      this.connId = editId;
      const res = await ServiceContainer.connectionManager.getById(this.connId);
      if (res.success && res.data !== null) {
        this.name = res.data.name;
        this.baseUrl = res.data.baseUrl;
        this.username = res.data.username;
        this.rootPath = res.data.rootPath;
        this.allowInsecure = res.data.allowInsecureHttp;
        this.lanUrl = res.data.lanUrl;
        this.wanUrl = res.data.wanUrl;
      }
    }
  }

  async save(): Promise<void> {
    const isEdit = this.connId !== '';
    if (this.baseUrl === '' || this.username === '' || (!isEdit && this.password === '')) {
      promptAction.showToast({ message: '请填写完整信息' });
      return;
    }
    const conn = new Connection();
    conn.id = this.connId;
    conn.name = this.name;
    conn.baseUrl = this.baseUrl;
    conn.username = this.username;
    conn.rootPath = this.rootPath;
    conn.allowInsecureHttp = this.allowInsecure;
    conn.lanUrl = this.lanUrl;
    conn.wanUrl = this.wanUrl;
    let savedId = this.connId;
    if (this.connId === '') {
      const res = await ServiceContainer.connectionManager.save(conn, this.password);
      savedId = res.success && res.data !== null ? res.data : '';
    } else {
      await ServiceContainer.connectionManager.update(conn, this.password);
    }
    if (savedId !== '') {
      await ServiceContainer.connectionManager.setActive(savedId);
    }
    promptAction.showToast({ message: '保存成功' });
    router.back();
  }

  async test(): Promise<void> {
    try {
      const conn = new Connection();
      conn.baseUrl = this.baseUrl;
      conn.username = this.username;
      conn.rootPath = this.rootPath;
      conn.allowInsecureHttp = this.allowInsecure;
      conn.lanUrl = this.lanUrl;
      conn.wanUrl = this.wanUrl;
      const res = await ServiceContainer.connectionManager.test(conn, this.password);
      promptAction.showToast({ message: res.success ? '连接成功' : ('连接失败：' + res.errorMessage) });
    } catch (e) {
      const err = e as BusinessError;
      promptAction.showToast({ message: '连接异常：' + err.message });
    }
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(14).opacity(this.hovBtn === 'back' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'back' : ''; })
          .onClick(() => { router.back(); })
        Text(this.connId === '' ? '新增连接' : '编辑连接').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark())).margin({ left: 8 })
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          Text('名称').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
          TextInput({ placeholder: '连接名称', text: this.name })
            .onChange((v: string) => { this.name = v; })
            .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark())).width('100%').height(44).margin({ bottom: 12 })
          Text('服务器地址').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
          TextInput({ placeholder: 'https://example.com:5006', text: this.baseUrl })
            .onChange((v: string) => { this.baseUrl = v; })
            .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark())).width('100%').height(44).margin({ bottom: 12 })
          Text('账号').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
          TextInput({ placeholder: '用户名', text: this.username })
            .onChange((v: string) => { this.username = v; })
            .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark())).width('100%').height(44).margin({ bottom: 12 })
          Text('密码').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
          TextInput({ placeholder: '密码或令牌', text: this.password })
            .type(InputType.Password)
            .onChange((v: string) => { this.password = v; })
            .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark())).width('100%').height(44).margin({ bottom: 12 })
          Text('根目录').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
          TextInput({ placeholder: '/', text: this.rootPath })
            .onChange((v: string) => { this.rootPath = v; })
            .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark())).width('100%').height(44).margin({ bottom: 12 })
          Text('局域网地址').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
          TextInput({ placeholder: 'https://192.168.1.100:5006（选填）', text: this.lanUrl })
            .onChange((v: string) => { this.lanUrl = v; })
            .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark())).width('100%').height(44).margin({ bottom: 12 })
          Text('外网地址').fontSize(14).fontColor(Theme.sub(this.isDark())).width('100%').margin({ bottom: 4 })
          TextInput({ placeholder: 'https://example.com:5006（选填）', text: this.wanUrl })
            .onChange((v: string) => { this.wanUrl = v; })
            .fontColor(Theme.fg(this.isDark())).backgroundColor(Theme.card(this.isDark())).placeholderColor(Theme.sub(this.isDark())).width('100%').height(44).margin({ bottom: 12 })
          Row() {
            Text('允许不安全 HTTP').fontSize(15).fontColor(Theme.fg(this.isDark()))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.allowInsecure }).onChange((on: boolean) => {
              this.allowInsecure = on;
            })
          }
          .width('100%')
          .padding(12)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)

      Row() {
        Button('测试连接').layoutWeight(1).margin({ left: 16, right: 8, bottom: 16 }).opacity(this.hovBtn === 'test' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'test' : ''; })
          .onClick(() => {
          this.test();
        })
        Button('保存').layoutWeight(1).margin({ left: 8, right: 16, bottom: 16 }).opacity(this.hovBtn === 'save' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'save' : ''; })
          .onClick(() => {
          this.save();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }

}