import { fileShare } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';

const TAG = 'WebDAVSync';

// A picker grant is temporary: it is dropped when the app exits or the device reboots.
// persistPermission keeps it, and activatePermission has to reload it into memory on every
// start — a persisted grant is still unusable without that call. Both take an access-mode
// bitmask, and WRITE_MODE does not imply read access, so persisting write alone leaves the
// folder unreadable after a restart and forces the user to pick it again.
export class UriPermission {
  static isUri(path: string): boolean {
    return path.startsWith('file://');
  }

  // Returns '' when the grant was persisted, otherwise the reason, for inline display.
  static async persist(uri: string): Promise<string> {
    const policy: fileShare.PolicyInfo = {
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
    };
    try {
      await fileShare.persistPermission([policy]);
      hilog.info(0x0000, TAG, 'persistPermission READ|WRITE ok: %{public}s', uri);
      return '';
    } catch (e) {
      const err = e as BusinessError<Array<fileShare.PolicyErrorResult>>;
      const detail = UriPermission.describe(err);
      hilog.error(0x0000, TAG, 'persistPermission failed code=%{public}d %{public}s', err.code, detail);
      return detail;
    }
  }

  // Every folder the app will touch this run goes in one call; the system resolves them
  // individually and reports the ones that were never persisted.
  static async activate(uris: string[]): Promise<boolean> {
    const policies: fileShare.PolicyInfo[] = [];
    for (const u of uris) {
      const policy: fileShare.PolicyInfo = {
        uri: u,
        operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
      };
      policies.push(policy);
    }
    try {
      await fileShare.activatePermission(policies);
      hilog.info(0x0000, TAG, 'activatePermission READ|WRITE ok for %{public}d uri(s)', policies.length);
      return true;
    } catch (e) {
      const err = e as BusinessError<Array<fileShare.PolicyErrorResult>>;
      hilog.error(0x0000, TAG, 'activatePermission failed code=%{public}d %{public}s', err.code, UriPermission.describe(err));
      return false;
    }
  }

  private static describe(err: BusinessError<Array<fileShare.PolicyErrorResult>>): string {
    const data = err.data;
    if (data === undefined || data === null || data.length === 0) {
      return err.message;
    }
    let out = err.message;
    for (let i = 0; i < data.length; i++) {
      // PolicyErrorCode: 1 forbidden to persist, 2 invalid mode, 3 invalid path, 4 not persisted.
      out = out + ' | ' + data[i].uri + ' code=' + data[i].code + ' ' + data[i].message;
    }
    return out;
  }
}
