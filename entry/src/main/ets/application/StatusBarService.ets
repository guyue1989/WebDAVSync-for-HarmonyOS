import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { image } from '@kit.ImageKit';
import { emitter, Callback } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { AppContext } from './AppContext';

const TAG = 'WebDAVSync';
const WHITE_ICON = 'tray_white.svg';
const BLACK_ICON = 'tray_black.svg';
const ICON_PX = 24;

// The top status-bar icon is the only entry point once the window is hidden, so it must exist
// before hideAbility() is called and be removed when the ability goes away.
export class StatusBarService {
  private added: boolean = false;
  private clickCallback: Callback<emitter.EventData> | null = null;

  async add(onIconClick: () => void): Promise<boolean> {
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return false;
    }
    try {
      const whiteData: Uint8Array = ctx.resourceManager.getRawFileContentSync(WHITE_ICON);
      const blackData: Uint8Array = ctx.resourceManager.getRawFileContentSync(BLACK_ICON);
      const icons: statusBarManager.StatusBarIcon = {
        white: await this.toPixelMap(whiteData),
        black: await this.toPixelMap(blackData)
      };
      // The left click opens the panel named here, and that panel immediately raises the main window
      // and closes itself. The alternative documented route (empty abilityName plus the
      // statusBarIconClick event) was tried first and never delivered a single click on this device.
      const operation: statusBarManager.QuickOperation = {
        abilityName: 'TrayPanelAbility',
        moduleName: 'entry',
        title: 'WebDAV 同步',
        height: 1
      };
      const openAction: statusBarManager.StatusBarMenuAction = {
        abilityName: 'EntryAbility',
        moduleName: 'entry'
      };
      const openItem: statusBarManager.StatusBarMenuItem = {
        title: '打开主界面',
        menuAction: openAction
      };
      const group: statusBarManager.StatusBarGroupMenu = [openItem];
      const item: statusBarManager.StatusBarItem = {
        icons: icons,
        quickOperation: operation,
        statusBarGroupMenu: [group],
        hoverTips: 'WebDAV 同步'
      };
      statusBarManager.addToStatusBar(ctx, item);
      // Kept only as a second channel and as evidence: this event needs an empty quickOperation
      // abilityName to be delivered, so with the panel configured it should stay silent.
      const cb: Callback<emitter.EventData> = (_data: emitter.EventData) => {
        hilog.info(0x0000, TAG, 'status bar icon clicked');
        onIconClick();
      };
      this.clickCallback = cb;
      statusBarManager.on('statusBarIconClick', cb);
      hilog.info(0x0000, TAG, 'left-click listener registered');
      this.added = true;
      hilog.info(0x0000, TAG, 'Status bar icon added');
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'Status bar icon unavailable code=%{public}d msg=%{public}s', err.code, err.message);
      return false;
    }
  }

  remove(): void {
    if (!this.added) {
      return;
    }
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return;
    }
    try {
      const cb = this.clickCallback;
      if (cb !== null) {
        statusBarManager.off('statusBarIconClick', cb);
      }
      this.clickCallback = null;
      statusBarManager.removeFromStatusBar(ctx);
      hilog.info(0x0000, TAG, 'Status bar icon removed');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'Status bar icon removal failed code=%{public}d msg=%{public}s', err.code, err.message);
    }
    this.added = false;
  }

  private async toPixelMap(data: Uint8Array): Promise<image.PixelMap> {
    const source = image.createImageSource(data.buffer);
    const info = source.getImageInfoSync();
    // The status bar wants a 24vp*24vp icon and refuses anything bigger; decoding an SVG without a
    // target size hands it a full-canvas raster and the host logs "the size of the pixelmap exceeds
    // the limit", which leaves the icon registered but its click business unreliable.
    const options: image.DecodingOptions = {
      editable: true,
      desiredSize: { width: ICON_PX, height: ICON_PX },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    };
    const pixelMap = await source.createPixelMap(options);
    hilog.info(0x0000, TAG, 'tray icon decoded %{public}d x %{public}d (source %{public}d x %{public}d)',
      ICON_PX, ICON_PX, info.size.width, info.size.height);
    source.release();
    return pixelMap;
  }
}
