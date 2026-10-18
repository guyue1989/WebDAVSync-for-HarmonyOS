import { ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import { AppContext } from './AppContext';

const TAG = 'WebDAVSync';

// The window title bar and the system-drawn controls follow the app color mode, not our JS palette,
// so a theme choice has to be pushed through setColorMode as well. Two constraints shape this class:
// setColorMode is only legal after loadContent() has drawn the page, and while a mode is pinned
// Configuration.colorMode echoes the pin instead of the system, so the system value is read back
// only in 'system' mode.
export class SystemTheme {
  static apply(mode: string): void {
    const ctx = AppContext.getContext();
    if (ctx === null) {
      hilog.warn(0x0000, TAG, 'setColorMode skipped: no context');
      return;
    }
    let target: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === 'dark') {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (mode === 'light') {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    try {
      ctx.getApplicationContext().setColorMode(target);
      hilog.info(0x0000, TAG, 'app color mode set: %{public}s', mode);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'setColorMode failed code=%{public}d msg=%{public}s', err.code, err.message);
    }
    SystemTheme.sync('apply', ctx.config.colorMode);
  }

  static sync(from: string, colorMode: ConfigurationConstant.ColorMode | undefined): void {
    if (AppStorage.get<string>('themeMode') !== 'system') {
      return;
    }
    if (colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      AppStorage.setOrCreate('systemDark', true);
      hilog.info(0x0000, TAG, 'system color mode dark from=%{public}s', from);
    } else if (colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      AppStorage.setOrCreate('systemDark', false);
      hilog.info(0x0000, TAG, 'system color mode light from=%{public}s', from);
    } else {
      // COLOR_MODE_NOT_SET / undefined: nothing reliable, so the previous value stays.
      const raw: number = colorMode === undefined ? -999 : colorMode;
      hilog.info(0x0000, TAG, 'system color mode unresolved from=%{public}s value=%{public}d', from, raw);
    }
  }
}
