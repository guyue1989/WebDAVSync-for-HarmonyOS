import router from '@ohos.router';
import { Theme } from '../application/Theme';
import { SystemTheme } from '../application/SystemTheme';

@Entry
@Component
struct Index {
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('systemDark') systemDark: boolean = false;
  @StorageProp('minimizeToTray') minimizeToTray: boolean = true;
  @State private hovCard: string = '';
  @State private hovTheme: string = '';

  private isDark(): boolean {
    return this.themeMode === 'dark' || (this.themeMode === 'system' && this.systemDark);
  }

  private applyTheme(mode: string): void {
    // themeMode first: SystemTheme.sync() only trusts Configuration.colorMode while in 'system' mode.
    AppStorage.setOrCreate('themeMode', mode);
    SystemTheme.apply(mode);
  }

  build() {
    Column() {
      Row() {
        Text('年槌糕同步').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark()))
        Blank()
        this.themeChip('跟随系统', 'system')
        this.themeChip('浅色', 'light')
        this.themeChip('深色', 'dark')
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)


      GridRow({
        columns: { sm: 4, md: 8, lg: 12 },
        breakpoints: { value: ['320vp', '600vp', '840vp'], reference: BreakpointsReference.WindowSize },
        gutter: 12
      }) {
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('连接管理', 'pages/ConnectionListPage')
        }
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('文件浏览', 'pages/FileBrowserPage')
        }
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('同步设置', 'pages/SyncSettingsPage')
        }
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('同步状态', 'pages/SyncStatusPage')
        }
      }
      .width('100%')
      .padding(16)

      Blank()

      Row() {
        Column() {
          Text('关闭后隐藏到顶部状态栏').fontSize(14).fontColor(Theme.fg(this.isDark()))
          Text('点状态栏图标重新打开，右键选退出才真正结束同步').fontSize(11).fontColor(Theme.sub(this.isDark())).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.minimizeToTray }).onChange((on: boolean) => {
          AppStorage.setOrCreate('minimizeToTray', on);
        })
      }
      .width('90%')
      .padding(14)
      .backgroundColor(Theme.card(this.isDark()))
      .borderRadius(10)
      .margin({ bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }

  @Builder
  themeChip(label: string, mode: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.themeMode === mode ? '#ffffff' : Theme.fg(this.isDark()))
      .backgroundColor(this.themeMode === mode ? Theme.primary(this.isDark())
        : (this.hovTheme === label ? Theme.cardHover(this.isDark()) : Theme.card(this.isDark())))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(8)
      .margin({ left: 8 })
      .onHover((h: boolean) => { this.hovTheme = h ? label : ''; })
      .onClick(() => { this.applyTheme(mode); })
  }

  @Builder
  menuItem(label: string, target: string) {
    Column() {
      Text(label).fontSize(18).fontWeight(FontWeight.Medium).fontColor(Theme.fg(this.isDark()))
    }
    .width('100%')
    .padding(28)
    .backgroundColor(this.hovCard === label ? Theme.cardHover(this.isDark()) : Theme.card(this.isDark()))
    .borderRadius(12)
    .margin({ bottom: 12 })
    .onHover((h: boolean) => { this.hovCard = h ? label : ''; })
    .onClick(() => {
      router.pushUrl({ url: target });
    })
  }
}