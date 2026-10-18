import preferences from '@ohos.data.preferences';
import { AppContext } from './AppContext';
import { SyncTask } from '../domain/SyncTask';
import { Result } from '../domain/Result';
import { SyncDirection } from '../domain/Enums';
import { ConflictStrategy } from '../domain/Enums';

const STORE_NAME = 'webdav_tasks';
const KEY_TASKS = 'tasks';

export interface ITaskManager {
  init(): Promise<Result<boolean>>;
  list(): Promise<Result<SyncTask[]>>;
  getById(id: string): Promise<Result<SyncTask | null>>;
  save(task: SyncTask): Promise<Result<string>>;
  remove(id: string): Promise<Result<boolean>>;
}

export class TaskManager implements ITaskManager {
  private pref: preferences.Preferences | null = null;

  async init(): Promise<Result<boolean>> {
    try {
      const ctx = AppContext.getContext();
      if (ctx === null) {
        return Result.fail(-1, 'context 为空');
      }
      this.pref = await preferences.getPreferences(ctx, STORE_NAME);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '任务存储初始化失败');
    }
  }

  private genId(): string {
    return 'task_' + Date.now().toString() + '_' + Math.floor(Math.random() * 10000).toString();
  }

  private async loadList(): Promise<SyncTask[]> {
    if (this.pref === null) {
      return [];
    }
    const json = await this.pref.get(KEY_TASKS, '[]') as string;
    const raw = JSON.parse(json) as SyncTask[];
    const result: SyncTask[] = [];
    for (const r of raw) {
      const t = new SyncTask();
      t.id = r.id !== undefined ? r.id : '';
      t.connectionId = r.connectionId !== undefined ? r.connectionId : '';
      t.localDir = r.localDir !== undefined ? r.localDir : '';
      t.remoteDir = r.remoteDir !== undefined ? r.remoteDir : '';
      t.direction = r.direction !== undefined ? r.direction : SyncDirection.Bidirectional;
      t.conflictStrategy = r.conflictStrategy !== undefined ? r.conflictStrategy : ConflictStrategy.CreateCopy;
      t.watchEnabled = r.watchEnabled !== undefined ? r.watchEnabled : true;
      t.debounceMs = r.debounceMs !== undefined ? r.debounceMs : 500;
      t.pollIntervalSec = r.pollIntervalSec !== undefined ? r.pollIntervalSec : 30;
      t.filterRules = r.filterRules !== undefined ? r.filterRules : '';
      t.concurrency = r.concurrency !== undefined ? r.concurrency : 2;
      result.push(t);
    }
    return result;
  }

  private async saveList(list: SyncTask[]): Promise<void> {
    if (this.pref === null) {
      return;
    }
    await this.pref.put(KEY_TASKS, JSON.stringify(list));
    await this.pref.flush();
  }

  async list(): Promise<Result<SyncTask[]>> {
    try {
      return Result.ok(await this.loadList());
    } catch (e) {
      return Result.fail(-1, '读取任务列表失败');
    }
  }

  async getById(id: string): Promise<Result<SyncTask | null>> {
    const list = await this.loadList();
    for (const t of list) {
      if (t.id === id) {
        return Result.ok(t);
      }
    }
    return Result.ok(null);
  }

  async save(task: SyncTask): Promise<Result<string>> {
    if (task.id === '') {
      task.id = this.genId();
    }
    const list = await this.loadList();
    const idx = list.findIndex((t: SyncTask) => t.id === task.id);
    if (idx >= 0) {
      list[idx] = task;
    } else {
      list.push(task);
    }
    await this.saveList(list);
    return Result.ok(task.id);
  }

  async remove(id: string): Promise<Result<boolean>> {
    const list = await this.loadList();
    const filtered = list.filter((t: SyncTask) => t.id !== id);
    await this.saveList(filtered);
    return Result.ok(true);
  }
}