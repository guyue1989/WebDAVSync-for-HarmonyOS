import hilog from '@ohos.hilog';
import { AppContext } from '../application/AppContext';

const TAG = 'WebDAVSync';

// The window must be raised only after the panel window itself is on screen: raising first makes the
// host draw the panel on top of the restored window, and the user has to click a second time.
//
// So every trigger the host gives gets its own raise, deliberately. A cooldown was tried and made
// things worse - it kept the earliest trigger and dropped the later ones, which are the ones that
// land above the panel. The main ability is a singleton, so the repeated raises are no-ops that only
// log; on this device a click reports foreground and the page's show event a few ms apart.
export class TrayRaise {
  private static handler: ((from: string) => void) | null = null;

  static setHandler(handler: ((from: string) => void) | null): void {
    TrayRaise.handler = handler;
  }

  static raise(from: string): void {
    hilog.info(0x0000, TAG, 'tray raise from=%{public}s', from);

    if (AppContext.restore()) {
      hilog.info(0x0000, TAG, 'main window restored through this process');
      return;
    }

    const handler = TrayRaise.handler;
    if (handler === null) {
      hilog.warn(0x0000, TAG, 'tray raise has no panel to launch the main ability with');
      return;
    }
    handler(from);
  }
}
