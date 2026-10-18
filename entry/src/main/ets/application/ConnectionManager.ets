import preferences from '@ohos.data.preferences';
import { AppContext } from './AppContext';
import { Connection } from '../domain/Connection';
import { Result } from '../domain/Result';
import { ISecureStore } from '../infrastructure/SecureStore';
import { IWebDavClient } from '../infrastructure/WebDavClient';
import { BusinessError } from '@ohos.base';

const STORE_NAME = 'webdav_connections';
const KEY_CONNECTIONS = 'connections';
const KEY_ACTIVE = 'active_id';

export interface IConnectionManager {
  init(): Promise<Result<boolean>>;
  list(): Promise<Result<Connection[]>>;
  getById(id: string): Promise<Result<Connection | null>>;
  save(conn: Connection, password: string): Promise<Result<string>>;
  update(conn: Connection, password: string): Promise<Result<boolean>>;
  remove(id: string): Promise<Result<boolean>>;
  setActive(id: string): Promise<Result<boolean>>;
  getActive(): Promise<Result<Connection | null>>;
  test(conn: Connection, password: string): Promise<Result<boolean>>;
}

export class ConnectionManager implements IConnectionManager {
  private pref: preferences.Preferences | null = null;
  private secureStore: ISecureStore;
  private webDavClient: IWebDavClient;

  constructor(secureStore: ISecureStore, webDavClient: IWebDavClient) {
    this.secureStore = secureStore;
    this.webDavClient = webDavClient;
  }

  async init(): Promise<Result<boolean>> {
    try {
      const ctx = AppContext.getContext();
      if (ctx === null) {
        return Result.fail(-1, 'context 为空');
      }
      this.pref = await preferences.getPreferences(ctx, STORE_NAME);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '连接存储初始化失败');
    }
  }

  private ready(): preferences.Preferences | null {
    return this.pref;
  }

  private genId(): string {
    return 'conn_' + Date.now().toString() + '_' + Math.floor(Math.random() * 10000).toString();
  }

  private copyConnection(src: Connection): Connection {
    const c = new Connection();
    c.id = src.id;
    c.name = src.name;
    c.baseUrl = src.baseUrl;
    c.username = src.username;
    c.credentialRef = src.credentialRef;
    c.rootPath = src.rootPath;
    c.allowInsecureHttp = src.allowInsecureHttp;
    c.lanUrl = src.lanUrl;
    c.wanUrl = src.wanUrl;
    return c;
  }

  private async loadList(): Promise<Connection[]> {
    const pref = this.ready();
    if (pref === null) {
      return [];
    }
    const json = await pref.get(KEY_CONNECTIONS, '[]') as string;
    const raw = JSON.parse(json) as Connection[];
    const result: Connection[] = [];
    for (const r of raw) {
      const c = new Connection();
      c.id = r.id !== undefined ? r.id : '';
      c.name = r.name !== undefined ? r.name : '';
      c.baseUrl = r.baseUrl !== undefined ? r.baseUrl : '';
      c.username = r.username !== undefined ? r.username : '';
      c.credentialRef = r.credentialRef !== undefined ? r.credentialRef : '';
      c.rootPath = r.rootPath !== undefined ? r.rootPath : '/';
      c.allowInsecureHttp = r.allowInsecureHttp !== undefined ? r.allowInsecureHttp : false;
      c.lanUrl = r.lanUrl !== undefined ? r.lanUrl : '';
      c.wanUrl = r.wanUrl !== undefined ? r.wanUrl : '';
      result.push(c);
    }
    return result;
  }

  private async saveList(list: Connection[]): Promise<void> {
    const pref = this.ready();
    if (pref === null) {
      return;
    }
    await pref.put(KEY_CONNECTIONS, JSON.stringify(list));
    await pref.flush();
  }

  async list(): Promise<Result<Connection[]>> {
    try {
      return Result.ok(await this.loadList());
    } catch (e) {
      return Result.fail(-1, '读取连接列表失败');
    }
  }

  async getById(id: string): Promise<Result<Connection | null>> {
    const list = await this.loadList();
    for (const c of list) {
      if (c.id === id) {
        return Result.ok(this.copyConnection(c));
      }
    }
    return Result.ok(null);
  }

  async save(conn: Connection, password: string): Promise<Result<string>> {
    if (conn.id === '') {
      conn.id = this.genId();
    }
    const refRes = await this.secureStore.saveCredential(conn.id, password);
    if (!refRes.success || refRes.data === null) {
      return Result.fail(-1, '保存凭证失败');
    }
    conn.credentialRef = refRes.data;
    const list = await this.loadList();
    const idx = list.findIndex((c: Connection) => c.id === conn.id);
    const copied = this.copyConnection(conn);
    if (idx >= 0) {
      list[idx] = copied;
    } else {
      list.push(copied);
    }
    await this.saveList(list);
    return Result.ok(conn.id);
  }

  async update(conn: Connection, password: string): Promise<Result<boolean>> {
    if (password !== '') {
      const refRes = await this.secureStore.saveCredential(conn.id, password);
      if (!refRes.success || refRes.data === null) {
        return Result.fail(-1, '更新凭证失败');
      }
      conn.credentialRef = refRes.data;
    }
    const list = await this.loadList();
    const idx = list.findIndex((c: Connection) => c.id === conn.id);
    if (idx >= 0) {
      list[idx] = this.copyConnection(conn);
      await this.saveList(list);
    }
    return Result.ok(true);
  }

  async remove(id: string): Promise<Result<boolean>> {
    try {
      const list = await this.loadList();
      const target = list.find((c: Connection) => c.id === id);
      if (target !== undefined && target.credentialRef !== '') {
        await this.secureStore.deleteCredential(target.credentialRef);
      }
      const filtered = list.filter((c: Connection) => c.id !== id);
      await this.saveList(filtered);
      const activeId = await this.pref?.get(KEY_ACTIVE, '');
      if (activeId === id) {
        const pref = this.ready();
        if (pref !== null) {
          await pref.put(KEY_ACTIVE, '');
          await pref.flush();
        }
      }
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '删除连接失败');
    }
  }

  async setActive(id: string): Promise<Result<boolean>> {
    const pref = this.ready();
    if (pref === null) {
      return Result.fail(-1, '存储未初始化');
    }
    await pref.put(KEY_ACTIVE, id);
    await pref.flush();
    return Result.ok(true);
  }

  async getActive(): Promise<Result<Connection | null>> {
    const pref = this.ready();
    if (pref === null) {
      return Result.fail(-1, '存储未初始化');
    }
    const activeId = await pref.get(KEY_ACTIVE, '') as string;
    if (activeId === '') {
      return Result.ok(null);
    }
    return this.getById(activeId);
  }

  async test(conn: Connection, password: string): Promise<Result<boolean>> {
    try {
      const refRes = await this.secureStore.saveCredential('temp_test', password);
      if (!refRes.success || refRes.data === null) {
        return Result.fail(-1, '保存临时凭证失败：' + refRes.errorMessage);
      }
      const copied = this.copyConnection(conn);
      copied.credentialRef = refRes.data;
      // An explicit test must try the addresses the user just typed, not the one the last
      // background pass happened to pick.
      this.webDavClient.invalidateAddress(copied.id);
      const res = await this.webDavClient.testConnection(copied);
      await this.secureStore.deleteCredential(refRes.data);
      return res;
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, '测试异常：' + err.message);
    }
  }
}