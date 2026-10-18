import preferences from '@ohos.data.preferences';
import { AppContext } from './AppContext';

const STORE_NAME = 'app_settings';

export class SettingsStore {
  static async put(key: string, value: string): Promise<void> {
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return;
    }
    const pref = await preferences.getPreferences(ctx, STORE_NAME);
    await pref.put(key, value);
    await pref.flush();
  }

  static async get(key: string): Promise<string> {
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return '';
    }
    const pref = await preferences.getPreferences(ctx, STORE_NAME);
    return await pref.get(key, '') as string;
  }
}