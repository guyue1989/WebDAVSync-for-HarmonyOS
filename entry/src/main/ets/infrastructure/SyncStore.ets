import relationalStore from '@ohos.data.relationalStore';
import { BusinessError } from '@ohos.base';
import { AppContext } from '../application/AppContext';
import { Result } from '../domain/Result';
import { FileState } from '../domain/FileState';
import { TransferCursor } from '../domain/TransferCursor';
import { Conflict } from '../domain/Conflict';
import { TransferDirection } from '../domain/Enums';
import { ConflictStrategy } from '../domain/Enums';

const DB_NAME = 'webdav_sync.db';

export interface ISyncStore {
  init(): Promise<Result<boolean>>;
  upsertFileState(state: FileState): Promise<Result<boolean>>;
  getFileState(taskId: string, relPath: string): Promise<Result<FileState | null>>;
  listFileStates(taskId: string): Promise<Result<Map<string, FileState>>>;
  clearTaskStates(taskId: string): Promise<Result<boolean>>;
  deleteFileState(taskId: string, relPath: string): Promise<Result<boolean>>;
  saveTransferCursor(cursor: TransferCursor): Promise<Result<boolean>>;
  getTransferCursor(transferId: string, relPath: string): Promise<Result<TransferCursor | null>>;
  deleteTransferCursor(transferId: string, relPath: string): Promise<Result<boolean>>;
  saveConflict(conflict: Conflict): Promise<Result<boolean>>;
  listConflicts(taskId: string): Promise<Result<Conflict[]>>;
  deleteConflict(taskId: string, relPath: string): Promise<Result<boolean>>;
}

export class SyncStore implements ISyncStore {
  private store: relationalStore.RdbStore | null = null;

  async init(): Promise<Result<boolean>> {
    try {
      const ctx = AppContext.getContext();
      if (ctx === null) {
        return Result.fail(-1, 'context 为空');
      }
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.store = await relationalStore.getRdbStore(ctx, config);
      await this.store.executeSql('CREATE TABLE IF NOT EXISTS file_state (' +
        'task_id TEXT NOT NULL, rel_path TEXT NOT NULL, local_mtime INTEGER, remote_mtime INTEGER, ' +
        'remote_etag TEXT, local_hash TEXT, conflict INTEGER, PRIMARY KEY (task_id, rel_path))');
      await this.store.executeSql('CREATE TABLE IF NOT EXISTS transfer_cursor (' +
        'transfer_id TEXT NOT NULL, rel_path TEXT NOT NULL, direction TEXT, transferred_bytes INTEGER, ' +
        'total_bytes INTEGER, updated_at INTEGER, PRIMARY KEY (transfer_id, rel_path))');
      await this.store.executeSql('CREATE TABLE IF NOT EXISTS conflict (' +
        'task_id TEXT NOT NULL, rel_path TEXT NOT NULL, local_mtime INTEGER, remote_mtime INTEGER, ' +
        'strategy TEXT, resolved INTEGER, PRIMARY KEY (task_id, rel_path))');
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  private ready(): relationalStore.RdbStore | null {
    return this.store;
  }

  async upsertFileState(state: FileState): Promise<Result<boolean>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      await store.executeSql('INSERT OR REPLACE INTO file_state ' +
        '(task_id, rel_path, local_mtime, remote_mtime, remote_etag, local_hash, conflict) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [state.taskId, state.relPath, state.localMtime, state.remoteMtime, state.remoteEtag, state.localHash, state.conflict ? 1 : 0]);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '写入文件状态失败');
    }
  }

  async getFileState(taskId: string, relPath: string): Promise<Result<FileState | null>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      const rs = await store.querySql('SELECT * FROM file_state WHERE task_id = ? AND rel_path = ?', [taskId, relPath]);
      let state: FileState | null = null;
      if (rs.goToFirstRow()) {
        state = this.rowToFileState(rs);
      }
      rs.close();
      return Result.ok(state);
    } catch (e) {
      return Result.fail(-1, '查询文件状态失败');
    }
  }

  async listFileStates(taskId: string): Promise<Result<Map<string, FileState>>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    const map = new Map<string, FileState>();
    try {
      const rs = await store.querySql('SELECT * FROM file_state WHERE task_id = ?', [taskId]);
      if (rs.goToFirstRow()) {
        do {
          const s = this.rowToFileState(rs);
          map.set(s.relPath, s);
        } while (rs.goToNextRow());
      }
      rs.close();
      return Result.ok(map);
    } catch (e) {
      return Result.fail(-1, '查询文件状态失败');
    }
  }

  private rowToFileState(rs: relationalStore.ResultSet): FileState {
    const s = new FileState();
    s.taskId = rs.getString(rs.getColumnIndex('task_id'));
    s.relPath = rs.getString(rs.getColumnIndex('rel_path'));
    s.localMtime = rs.getLong(rs.getColumnIndex('local_mtime'));
    s.remoteMtime = rs.getLong(rs.getColumnIndex('remote_mtime'));
    s.remoteEtag = rs.getString(rs.getColumnIndex('remote_etag'));
    s.localHash = rs.getString(rs.getColumnIndex('local_hash'));
    s.conflict = rs.getLong(rs.getColumnIndex('conflict')) === 1;
    return s;
  }

  private parseDirection(v: string): TransferDirection {
    return v === 'upload' ? TransferDirection.Upload : TransferDirection.Download;
  }

  private parseStrategy(v: string): ConflictStrategy {
    if (v === 'keep_local') {
      return ConflictStrategy.KeepLocal;
    }
    if (v === 'keep_remote') {
      return ConflictStrategy.KeepRemote;
    }
    if (v === 'manual') {
      return ConflictStrategy.ManualResolve;
    }
    return ConflictStrategy.CreateCopy;
  }

  async clearTaskStates(taskId: string): Promise<Result<boolean>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      await store.executeSql('DELETE FROM file_state WHERE task_id = ?', [taskId]);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '清理文件状态失败');
    }
  }

  async deleteFileState(taskId: string, relPath: string): Promise<Result<boolean>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      await store.executeSql('DELETE FROM file_state WHERE task_id = ? AND rel_path = ?', [taskId, relPath]);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '删除文件状态失败');
    }
  }

  async saveTransferCursor(cursor: TransferCursor): Promise<Result<boolean>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      await store.executeSql('INSERT OR REPLACE INTO transfer_cursor ' +
        '(transfer_id, rel_path, direction, transferred_bytes, total_bytes, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [cursor.transferId, cursor.relPath, cursor.direction, cursor.transferredBytes, cursor.totalBytes, cursor.updatedAt]);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '保存断点游标失败');
    }
  }

  async getTransferCursor(transferId: string, relPath: string): Promise<Result<TransferCursor | null>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      const rs = await store.querySql('SELECT * FROM transfer_cursor WHERE transfer_id = ? AND rel_path = ?', [transferId, relPath]);
      let cursor: TransferCursor | null = null;
      if (rs.goToFirstRow()) {
        cursor = new TransferCursor();
        cursor.transferId = rs.getString(rs.getColumnIndex('transfer_id'));
        cursor.relPath = rs.getString(rs.getColumnIndex('rel_path'));
        cursor.direction = this.parseDirection(rs.getString(rs.getColumnIndex('direction')));
        cursor.transferredBytes = rs.getLong(rs.getColumnIndex('transferred_bytes'));
        cursor.totalBytes = rs.getLong(rs.getColumnIndex('total_bytes'));
        cursor.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
      }
      rs.close();
      return Result.ok(cursor);
    } catch (e) {
      return Result.fail(-1, '查询断点游标失败');
    }
  }

  async deleteTransferCursor(transferId: string, relPath: string): Promise<Result<boolean>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      await store.executeSql('DELETE FROM transfer_cursor WHERE transfer_id = ? AND rel_path = ?', [transferId, relPath]);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '删除断点游标失败');
    }
  }

  async saveConflict(conflict: Conflict): Promise<Result<boolean>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      await store.executeSql('INSERT OR REPLACE INTO conflict ' +
        '(task_id, rel_path, local_mtime, remote_mtime, strategy, resolved) VALUES (?, ?, ?, ?, ?, ?)',
        [conflict.taskId, conflict.relPath, conflict.localMtime, conflict.remoteMtime, conflict.strategy, conflict.resolved ? 1 : 0]);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '保存冲突失败');
    }
  }

  async listConflicts(taskId: string): Promise<Result<Conflict[]>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    const list: Conflict[] = [];
    try {
      const rs = await store.querySql('SELECT * FROM conflict WHERE task_id = ?', [taskId]);
      if (rs.goToFirstRow()) {
        do {
          const c = new Conflict();
          c.taskId = rs.getString(rs.getColumnIndex('task_id'));
          c.relPath = rs.getString(rs.getColumnIndex('rel_path'));
          c.localMtime = rs.getLong(rs.getColumnIndex('local_mtime'));
          c.remoteMtime = rs.getLong(rs.getColumnIndex('remote_mtime'));
          c.strategy = this.parseStrategy(rs.getString(rs.getColumnIndex('strategy')));
          c.resolved = rs.getLong(rs.getColumnIndex('resolved')) === 1;
          list.push(c);
        } while (rs.goToNextRow());
      }
      rs.close();
      return Result.ok(list);
    } catch (e) {
      return Result.fail(-1, '查询冲突失败');
    }
  }

  async deleteConflict(taskId: string, relPath: string): Promise<Result<boolean>> {
    const store = this.ready();
    if (store === null) {
      return Result.fail(-1, '存储未初始化');
    }
    try {
      await store.executeSql('DELETE FROM conflict WHERE task_id = ? AND rel_path = ?', [taskId, relPath]);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '删除冲突失败');
    }
  }
}