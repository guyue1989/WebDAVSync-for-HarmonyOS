import { StatusBarViewExtensionAbility } from '@kit.DeskTopExtensionKit';
import { UIExtensionContentSession, Want } from '@kit.AbilityKit';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { TrayRaise } from './TrayRaise';

const TAG = 'WebDAVSync';
const BUNDLE_NAME = 'com.niangao.webdavsync';

// Left click on the status-bar icon opens this panel: it is the only left-click channel this device
// delivers, the documented statusBarIconClick event never fires. It runs in its own process, so the
// window comes back by launching the singleton ability rather than by calling showAbility() here.
//
// The session is never closed by us. terminateSelf() - on open or after the main window steals the
// focus back - makes the host reopen the panel about 100 ms later, and that reopened empty panel is
// drawn on top of the window we just restored, which is what read as "the icon needs two clicks".
// Leaving the session alone costs nothing: the host hides its window when the main window is raised,
// and the next click only re-shows this session, whose foreground event raises the window again.
export default class TrayPanelAbility extends StatusBarViewExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    hilog.info(0x0000, TAG, 'tray panel session created');
    TrayRaise.setHandler((from: string) => {
      this.startMainWindow(from);
    });
    try {
      session.loadContent('pages/TrayPanelPage');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'tray panel content failed code=%{public}d msg=%{public}s', err.code, err.message);
    }
    // Raise in the same tick as loadContent: the empty card is only the panel window getting drawn
    // for one frame before the main window takes the focus back, so the earlier the window comes up,
    // the less of that frame the user sees.
    TrayRaise.raise('create');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'tray panel foreground');
    TrayRaise.raise('foreground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'tray panel background');
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'tray panel destroyed');
    TrayRaise.setHandler(null);
  }

  private startMainWindow(from: string): void {
    const target: Want = { bundleName: BUNDLE_NAME, abilityName: 'EntryAbility' };
    this.context.startAbility(target).then(() => {
      hilog.info(0x0000, TAG, 'main ability raised from=%{public}s', from);
    }).catch((e: BusinessError) => {
      hilog.error(0x0000, TAG, 'tray raise from=%{public}s failed code=%{public}d msg=%{public}s',
        from, e.code, e.message);
    });
  }
}
