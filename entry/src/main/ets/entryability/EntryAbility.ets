import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import preferences from '@ohos.data.preferences';
import { Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { AppContext } from '../application/AppContext';
import { ServiceContainer } from '../application/ServiceContainer';
import { SystemTheme } from '../application/SystemTheme';
import { UriPermission } from '../application/UriPermission';

const TAG = 'WebDAVSync';
const BUNDLE_NAME = 'com.niangao.webdavsync';

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | null = null;
  private mainWindow: window.Window | null = null;
  private hasTrayIcon: boolean = false;
  private isHidden: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppContext.setContext(this.context);
    PersistentStorage.persistProp('themeMode', 'system');
    PersistentStorage.persistProp('minimizeToTray', true);
    PersistentStorage.persistProp('selectedLocalDir', '');
    // The theme default is 'system': an unset preference follows the desktop, a set one comes back
    // from the store. Seed systemDark from the live configuration because the first frame is drawn
    // before SystemTheme.apply() runs, and a hard false would flash a light UI on a dark system.
    AppStorage.setOrCreate('systemDark',
      this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    hilog.info(0x0000, TAG, 'onCreate: PersistentStorage initialized');
    ServiceContainer.init().then(async () => {
      hilog.info(0x0000, TAG, 'ServiceContainer initialized');
      await this.activateUriPermission();
      ServiceContainer.startupSync().then(() => {
        hilog.info(0x0000, TAG, 'startup sync finished');
      });
    });
    hilog.info(0x0000, TAG, 'EntryAbility onCreate');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    SystemTheme.sync('onConfigurationUpdate', newConfig.colorMode);
  }

  private async activateUriPermission(): Promise<void> {
    const ctx = AppContext.getContext();
    if (ctx === null) {
      hilog.warn(0x0000, TAG, 'activateUriPermission: context is null');
      return;
    }
    
    let savedDir = '';
    try {
      const pref = await preferences.getPreferences(ctx, 'app_settings');
      savedDir = await pref.get('selectedLocalDir', '') as string;
      hilog.info(0x0000, TAG, 'Preferences read: selectedLocalDir=%{public}s', savedDir !== '' ? savedDir : '(empty)');
      if (savedDir !== '') {
        AppStorage.setOrCreate('selectedLocalDir', savedDir);
      }
      const savedRemote = await pref.get('selectedRemoteDir', '') as string;
      if (savedRemote !== '') {
        AppStorage.setOrCreate('selectedRemoteDir', savedRemote);
      }
    } catch (e) {
      const err = e as Error;
      hilog.error(0x0000, TAG, 'Preferences read failed: %{public}s', err.message);
    }
    
    hilog.info(0x0000, TAG, 'activateUriPermission: savedDir=%{public}s', savedDir !== '' ? savedDir : '(empty)');
    // Each task keeps its own copy of the folder, so every distinct URI has to be activated,
    // not just the globally selected one.
    const uris: string[] = [];
    if (UriPermission.isUri(savedDir)) {
      uris.push(savedDir);
    }
    const tasks = await ServiceContainer.taskManager.list();
    if (tasks.success && tasks.data !== null) {
      for (const t of tasks.data) {
        if (UriPermission.isUri(t.localDir) && uris.indexOf(t.localDir) < 0) {
          uris.push(t.localDir);
        }
      }
    }
    if (uris.length === 0) {
      hilog.info(0x0000, TAG, 'activateUriPermission: skipping (no persisted URI)');
      return;
    }
    await UriPermission.activate(uris);

    // Listing is the only reliable check that the grant is actually live: fs.access succeeds
    // without one. A folder that fails here has to be picked again.
    for (const u of uris) {
      const plainPath = ServiceContainer.localFileService.toPath(u);
      try {
        const names = await fs.listFile(plainPath);
        hilog.info(0x0000, TAG, 'grant verified: %{public}d entries in %{public}s', names.length, plainPath);
      } catch (verifyErr) {
        const err = verifyErr as BusinessError;
        hilog.error(0x0000, TAG, 'grant unusable code=%{public}d msg=%{public}s for %{public}s', err.code, err.message, plainPath);
      }
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;

    windowStage.getMainWindow().then((win: window.Window) => {
      this.mainWindow = win;
    }).catch((e: Error) => {
      hilog.error(0x0000, TAG, 'Failed to get main window: %{public}s', e.message);
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      // setColorMode is only legal once the page has been drawn, so the stored theme is applied here
      // rather than in onCreate; without it the title bar keeps the system palette.
      const storedTheme = AppStorage.get<string>('themeMode');
      SystemTheme.apply(storedTheme === undefined ? 'system' : storedTheme);
      this.hideInsteadOfClose(windowStage);
      // The status-bar left-click panel runs as its own ability and can only ask for the window here;
      // it must not guess whether this one was hidden or merely minimized.
      AppContext.setRestoreHandler(() => {
        this.showMainWindow(true);
      });
      ServiceContainer.statusBarService.add(() => {
        this.showMainWindow(true);
      }).then((ok: boolean) => {
        this.hasTrayIcon = ok;
      });
      hilog.info(0x0000, TAG, 'Succeeded in loading content');
    });
  }

  // The title-bar X must not kill the sync, so the close request is turned into hideAbility(): the
  // window and its Dock entry disappear while the UIAbility keeps running, and the status-bar icon
  // stays as the way back in. minimize() would have left the Dock icon in place.
  // windowStageClose fires only for the free-window state; a maximized window on 6.1+ closes
  // normally without an error, so the log tells us which case we are actually in.
  private hideInsteadOfClose(windowStage: window.WindowStage): void {
    try {
      windowStage.on('windowStageClose', () => {
        if (AppStorage.get<boolean>('minimizeToTray') !== true) {
          hilog.info(0x0000, TAG, 'close accepted (minimizeToTray off)');
          return false;
        }
        this.hideToTray();
        return true;
      });
      hilog.info(0x0000, TAG, 'windowStageClose listener registered');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'windowStageClose unavailable code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  private hideToTray(): void {
    if (this.isHidden) {
      return;
    }
    if (!this.hasTrayIcon) {
      // hideAbility() requires a status-bar icon; without one the window can only be minimized.
      this.minimizeFallback();
      return;
    }
    this.isHidden = true;
    this.context.hideAbility().then(() => {
      hilog.info(0x0000, TAG, 'close intercepted: ability hidden, status bar icon is the entry');
    }).catch((e: BusinessError) => {
      hilog.warn(0x0000, TAG, 'hideAbility failed code=%{public}d msg=%{public}s', e.code, e.message);
      this.isHidden = false;
      this.minimizeFallback();
    });
  }

  private minimizeFallback(): void {
    const win = this.mainWindow;
    if (win === null) {
      hilog.warn(0x0000, TAG, 'close intercepted but no main window');
      return;
    }
    win.minimize().then(() => {
      hilog.info(0x0000, TAG, 'close intercepted: window minimized');
    }).catch((e: BusinessError) => {
      hilog.error(0x0000, TAG, 'minimize failed code=%{public}d msg=%{public}s', e.code, e.message);
    });
  }

  private showMainWindow(fromIcon: boolean): void {
    hilog.info(0x0000, TAG, 'showMainWindow hidden=%{public}s fromIcon=%{public}s',
      this.isHidden ? 'true' : 'false', fromIcon ? 'true' : 'false');
    if (this.isHidden) {
      this.isHidden = false;
      this.context.showAbility().then(() => {
        hilog.info(0x0000, TAG, 'ability restored from status bar');
      }).catch((e: BusinessError) => {
        hilog.warn(0x0000, TAG, 'showAbility failed code=%{public}d msg=%{public}s', e.code, e.message);
      });
      return;
    }
    // Nothing went through hideAbility, so the window is only minimized — and showAbility() cannot
    // undo a minimize. Starting the singleton again is exactly what the status-bar menu does to raise
    // it; the resulting onNewWant must not loop back into this branch.
    if (fromIcon) {
      const want: Want = { bundleName: BUNDLE_NAME, abilityName: 'EntryAbility' };
      this.context.startAbility(want).then(() => {
        hilog.info(0x0000, TAG, 'ability re-started from icon click');
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'startAbility failed code=%{public}d msg=%{public}s', e.code, e.message);
      });
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // The status-bar menu (and the background notification) restart this singleton ability; a hidden
    // ability is not unhidden by that, so show the window here. Not from the icon: re-starting from
    // here would send the click path round in a circle.
    this.showMainWindow(false);
  }

  onWindowStageDestroy(): void {
    this.mainWindow = null;
    this.windowStage = null;
    hilog.info(0x0000, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'EntryAbility onForeground');
    ServiceContainer.trayService.hide();
    // Coming back is the one moment a keepalive the user dismissed can be asked for again.
    ServiceContainer.backgroundTaskService.reacquire();
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'EntryAbility onBackground');
    // Closing the window to the status bar moves the ability to the background, where the process
    // is suspended unless a continuous task is held — and a suspended process stops every timer,
    // which is what made the tray-resident sync sleep until the window was reopened.
    ServiceContainer.backgroundTaskService.start();
    const minimize = AppStorage.get<boolean>('minimizeToTray');
    if (minimize === true) {
      ServiceContainer.trayService.show();
    }
  }

  onDestroy(): void {
    AppContext.setRestoreHandler(null);
    ServiceContainer.statusBarService.remove();
    ServiceContainer.trayService.hide();
    hilog.info(0x0000, TAG, 'EntryAbility onDestroy');
  }
}
