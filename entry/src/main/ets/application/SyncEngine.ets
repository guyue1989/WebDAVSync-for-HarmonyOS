import { Connection } from '../domain/Connection';
import { SyncTask } from '../domain/SyncTask';
import { SyncResult } from '../domain/SyncResult';
import { FileState } from '../domain/FileState';
import { FileEntry } from '../domain/FileEntry';
import { Conflict } from '../domain/Conflict';
import { SyncStatus } from '../domain/Enums';
import { ConflictStrategy } from '../domain/Enums';
import { SyncDirection } from '../domain/Enums';
import { Result } from '../domain/Result';
import { IWebDavClient } from '../infrastructure/WebDavClient';
import { ILocalFileService } from '../infrastructure/LocalFileService';
import { ISyncStore } from '../infrastructure/SyncStore';
import { IConnectionManager } from './ConnectionManager';
import { AppContext } from './AppContext';
import { FileEvent } from '../infrastructure/FileWatcher';
import { ChangeDetector } from '../domain/ChangeDetector';
import { SyncProgressTracker } from './SyncProgressTracker';
import { FileFilter } from '../domain/FileFilter';
import { LongNameMapper } from '../domain/LongNameMapper';
import hilog from '@ohos.hilog';

const LWW_EPSILON = 2;

enum ActionType {
  Upload = 0,
  Download = 1,
  DeleteLocal = 2,
  DeleteRemote = 3,
  MkdirLocal = 4,
  MkdirRemote = 5
}

class SyncAction {
  relPath: string = '';
  type: ActionType = ActionType.Upload;
  isDirectory: boolean = false;
}

class SyncPlan {
  actions: SyncAction[] = [];
  conflicts: Conflict[] = [];
}

class RemoteSweep {
  entries: Map<string, FileEntry> = new Map<string, FileEntry>();
  incomplete: boolean = false;
}

export interface ISyncEngine {
  startSync(task: SyncTask): Promise<SyncResult>;
  onLocalChange(task: SyncTask, events: FileEvent[]): Promise<SyncResult>;
  pullRemoteChanges(task: SyncTask): Promise<SyncResult>;
  resolveConflict(task: SyncTask, conflict: Conflict, strategy: ConflictStrategy): Promise<Result<boolean>>;
  stopSync(taskId: string): Promise<void>;
  pauseSync(taskId: string): Promise<void>;
  isPaused(taskId: string): boolean;
}

export class SyncEngine implements ISyncEngine {
  private webDavClient: IWebDavClient;
  private localFileService: ILocalFileService;
  private syncStore: ISyncStore;
  private connectionManager: IConnectionManager;
  private cancelled: Set<string> = new Set<string>();
  private running: Set<string> = new Set<string>();
  private paused: Set<string> = new Set<string>();

  constructor(webDavClient: IWebDavClient, localFileService: ILocalFileService, syncStore: ISyncStore, connectionManager: IConnectionManager) {
    this.webDavClient = webDavClient;
    this.localFileService = localFileService;
    this.syncStore = syncStore;
    this.connectionManager = connectionManager;
  }

  async startSync(task: SyncTask): Promise<SyncResult> {
    // An explicit sync click also lifts a pause, and the pass picks up where the
    // cancelled one stopped because progress is stored per file.
    this.paused.delete(task.id);
    this.cancelled.delete(task.id);
    return this.synchronize(task, false);
  }

  async onLocalChange(task: SyncTask, events: FileEvent[]): Promise<SyncResult> {
    // The user just changed something, so the pass that follows is expected and must show up.
    return this.synchronize(task, false);
  }

  async pullRemoteChanges(task: SyncTask): Promise<SyncResult> {
    // Timer driven. Most of these passes find nothing, and announcing every one of them turns
    // the status page into noise; it becomes visible only once the plan has work.
    return this.synchronize(task, true);
  }

  async stopSync(taskId: string): Promise<void> {
    this.cancelled.add(taskId);
  }

  async pauseSync(taskId: string): Promise<void> {
    this.paused.add(taskId);
    this.cancelled.add(taskId);
  }

  isPaused(taskId: string): boolean {
    return this.paused.has(taskId);
  }

  private remoteRelPath(task: SyncTask, relPath: string): string {
    const root = task.remoteDir.replace(/\/+$/, '');
    return root + '/' + relPath;
  }

  // Plan keys are always the remote (original) paths; only the name on disk is shortened,
  // because HarmonyOS refuses path components longer than 255 bytes. The mapping is
  // deterministic, so no extra state has to be kept.
  private localPathFor(task: SyncTask, relPath: string): string {
    return this.localFileService.joinPath(task.localDir, LongNameMapper.toLocalRel(relPath));
  }

  // Report a shortened local file under the remote name it came from, otherwise the two
  // snapshots never line up and that file syncs back and forth forever.
  private applyLocalAliases(localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): void {
    const toOriginal = new Map<string, string>();
    remoteSnap.forEach((v: FileEntry, remoteRel: string) => {
      if (LongNameMapper.needsShortening(remoteRel)) {
        toOriginal.set(LongNameMapper.toLocalRel(remoteRel), remoteRel);
      }
    });
    if (toOriginal.size === 0) {
      return;
    }
    const hits: string[] = [];
    localSnap.forEach((v: FileEntry, k: string) => {
      if (toOriginal.has(k)) {
        hits.push(k);
      }
    });
    for (const k of hits) {
      const entry = localSnap.get(k);
      const original = toOriginal.get(k);
      if (entry !== undefined && original !== undefined) {
        localSnap.delete(k);
        localSnap.set(original, entry);
      }
    }
  }

  private async synchronize(task: SyncTask, quiet: boolean): Promise<SyncResult> {
    if (this.paused.has(task.id)) {
      const idle = new SyncResult();
      idle.taskId = task.id;
      idle.status = SyncStatus.Paused;
      idle.message = '任务已暂停';
      return idle;
    }
    if (this.running.has(task.id)) {
      const busy = new SyncResult();
      busy.taskId = task.id;
      busy.status = SyncStatus.Error;
      busy.busy = true;
      busy.message = '该任务正在同步中';
      return busy;
    }
    this.running.add(task.id);
    // The compare phase takes seconds on a large vault, so the pass announces itself right
    // away instead of leaving the status page silent until the plan exists. A background poll that
    // finds nothing to do is quiet; the page only shows this once the plan has work.
    SyncProgressTracker.begin(task.id, 0, '检查变更：比对本地与 NAS…', quiet);
    try {
      return await this.doSynchronize(task);
    } finally {
      this.running.delete(task.id);
      SyncProgressTracker.finish(task.id);
    }
  }

  private async doSynchronize(task: SyncTask): Promise<SyncResult> {
    const result = new SyncResult();
    result.taskId = task.id;
    result.status = SyncStatus.Comparing;
    this.cancelled.delete(task.id);

    const connRes = await this.connectionManager.getById(task.connectionId);
    if (!connRes.success || connRes.data === null) {
      result.status = SyncStatus.Error;
      result.message = '连接不存在';
      return result;
    }
    const conn = connRes.data;

    await this.webDavClient.resolveAddress(conn);

    let localDir = task.localDir;
    if (localDir.startsWith('file://')) {
      const slash = localDir.indexOf('/', 7);
      localDir = slash < 0 ? '/' : localDir.substring(slash);
    }
    if (!localDir.startsWith('/')) {
      const ctx = AppContext.getContext();
      if (ctx !== null) {
        localDir = ctx.filesDir + '/sync';
      }
    }
    task.localDir = localDir;

    if (!await this.localFileService.exists(localDir)) {
      await this.localFileService.ensureDir(task.localDir);
    }

    const localRes = await this.localFileService.readSnapshot(task.localDir);
    hilog.info(0x0000, 'WebDAVSync', 'Local snapshot: dir=%{public}s, success=%{public}s, size=%{public}s',
      task.localDir, String(localRes.success), localRes.data !== null ? String(localRes.data.size) : 'null');
    if (!localRes.success || localRes.data === null) {
      result.status = SyncStatus.Error;
      result.message = '读取本地目录失败：' + localRes.errorMessage;
      return result;
    }
    const localSnap = localRes.data;

    const sweep = await this.buildRemoteSnapshot(conn, task.remoteDir);
    hilog.info(0x0000, 'WebDAVSync', 'Remote snapshot: size=%{public}d incomplete=%{public}s',
      sweep.entries.size, String(sweep.incomplete));
    if (sweep.incomplete) {
      // A listing that failed part way through is indistinguishable from "the NAS deleted
      // it", and this pass would then delete local files and folders that are still there.
      // Nothing is transferred and no state is written; the next pass retries.
      // The address just stopped answering for part of the tree, so re-resolve it next time.
      this.webDavClient.invalidateAddress(conn.id);
      result.status = SyncStatus.Error;
      result.message = '读取远端目录失败，本轮不做任何变更';
      return result;
    }
    const remoteSnap = sweep.entries;
    this.applyLocalAliases(localSnap, remoteSnap);

    const statesRes = await this.syncStore.listFileStates(task.id);
    const fileStates = statesRes.success && statesRes.data !== null ? statesRes.data : new Map<string, FileState>();

    const plan = this.computePlan(task, localSnap, remoteSnap, fileStates, task.direction);
    hilog.info(0x0000, 'WebDAVSync', 'computePlan: actions=%{public}d conflicts=%{public}d', plan.actions.length, plan.conflicts.length);

    if (plan.actions.length === 0 && plan.conflicts.length === 0) {
      await this.rebuildFileStates(task, localSnap, remoteSnap, fileStates);
      result.status = SyncStatus.Completed;
      result.message = '无变化';
      return result;
    }

    const planSummary = this.describePlan(plan);
    SyncProgressTracker.update(task.id, plan.actions.length + plan.conflicts.length, planSummary);
    hilog.info(0x0000, 'WebDAVSync', 'plan %{public}s', planSummary);

    // Everything this pass writes, renames or removes on the local side. The file watcher needs
    // it to tell its own work apart from a change the user made while the pass was running.
    for (const a of plan.actions) {
      if (a.type === ActionType.Download || a.type === ActionType.DeleteLocal || a.type === ActionType.MkdirLocal) {
        result.localTouched.push(a.relPath);
      }
    }
    for (const c of plan.conflicts) {
      result.localTouched.push(c.relPath);
    }

    result.status = SyncStatus.Transferring;
    result.conflicts = plan.conflicts;

    await this.executeRemoteMkdirs(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeUploads(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeLocalMkdirs(task, plan, result, localSnap, remoteSnap);
    await this.executeDownloads(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeRemoteDeletes(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeLocalDeletes(task, plan, result, localSnap, remoteSnap);

    if (plan.conflicts.length > 0) {
      result.status = SyncStatus.Resolving;
      for (const c of plan.conflicts) {
        await this.applyConflictStrategy(task, conn, c, task.conflictStrategy, result, localSnap, remoteSnap);
        SyncProgressTracker.step(task.id, '处理冲突', c.relPath);
      }
    }

    // A cancelled pass must not rewrite the state table: the files it never reached
    // would be recorded as synced and lost from the resume list.
    if (this.cancelled.has(task.id)) {
      hilog.info(0x0000, 'WebDAVSync', 'sync paused: transferred=%{public}d failed=%{public}d', result.transferred, result.failedCount);
      result.status = SyncStatus.Paused;
      result.message = '已暂停，剩余项稍后继续';
      return result;
    }

    await this.rebuildFileStates(task, localSnap, remoteSnap, fileStates);

    hilog.info(0x0000, 'WebDAVSync', 'sync completed: transferred=%{public}d failed=%{public}d', result.transferred, result.failedCount);

    result.status = SyncStatus.Completed;
    // The progress block disappears the moment the pass ends, so this notice has to carry
    // what the pass actually did and in which direction.
    result.message = '同步完成 ' + planSummary +
      (result.failedCount > 0 ? '（' + result.failedCount.toString() + ' 项失败）' : '');
    return result;
  }

  private async buildRemoteSnapshot(conn: Connection, remoteRoot: string): Promise<RemoteSweep> {
    const sweep = new RemoteSweep();
    await this.walkRemote(conn, remoteRoot, '', sweep, true);
    return sweep;
  }

  private async walkRemote(conn: Connection, remoteDir: string, relPrefix: string, sweep: RemoteSweep, isRoot: boolean): Promise<void> {
    const res = await this.webDavClient.listDirectory(conn, remoteDir);
    if (!res.success || res.data === null) {
      // An empty remote snapshot is otherwise indistinguishable from a failed PROPFIND.
      hilog.error(0x0000, 'WebDAVSync', 'walkRemote FAIL dir=%{public}s code=%{public}d msg=%{public}s',
        remoteDir, res.errorCode, res.errorMessage);
      if (isRoot && (res.errorCode === 404 || res.errorCode === 405)) {
        // The task's remote folder was never created or has been deleted: that is simply an
        // empty remote, so create it and let the pass upload the local tree into it.
        await this.webDavClient.mkdir(conn, remoteDir);
        return;
      }
      sweep.incomplete = true;
      return;
    }
    for (const entry of res.data) {
      const rel = relPrefix === '' ? entry.name : relPrefix + '/' + entry.name;
      sweep.entries.set(rel, entry);
      if (entry.isDirectory) {
        const childRemote = remoteDir.replace(/\/+$/, '') + '/' + entry.name;
        await this.walkRemote(conn, childRemote, rel, sweep, false);
      }
    }
  }

  private computePlan(task: SyncTask, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>, fileStates: Map<string, FileState>, direction: SyncDirection): SyncPlan {
    const plan = new SyncPlan();
    const filter = new FileFilter(task.filterRules);
    const keys = new Set<string>();
    localSnap.forEach((v: FileEntry, k: string) => keys.add(k));
    remoteSnap.forEach((v: FileEntry, k: string) => keys.add(k));
    fileStates.forEach((v: FileState, k: string) => keys.add(k));

    keys.forEach((path: string) => {
      if (this.isFiltered(filter, path)) {
        return;
      }
      if (path.endsWith('.part')) {
        // The app's own download staging file. An interrupted pass leaves one behind, and
        // treating it as a local-only file would put a garbage copy on the NAS.
        return;
      }
      const localEntry = localSnap.get(path);
      const remoteEntry = remoteSnap.get(path);
      const prev = fileStates.get(path);

      const localExists = localEntry !== undefined;
      const remoteExists = remoteEntry !== undefined;
      const isDir = (localEntry !== undefined && localEntry.isDirectory) || (remoteEntry !== undefined && remoteEntry.isDirectory);

      // A folder has no content of its own and its mtime shifts every time a child is added
      // or removed, so folders are judged by existence plus the stored baseline: gone from the
      // NAS while it was synced means deleted there, so it goes locally too; a folder only one
      // side has is simply created on the other.
      if (isDir) {
        if (localExists === remoteExists) {
          return;
        }
        if (localExists) {
          if (prev !== undefined && direction === SyncDirection.Bidirectional) {
            plan.actions.push(this.makeAction(path, ActionType.DeleteLocal, true));
          } else {
            plan.actions.push(this.makeAction(path, ActionType.MkdirRemote, true));
          }
        } else if (prev !== undefined && direction === SyncDirection.Bidirectional) {
          plan.actions.push(this.makeAction(path, ActionType.DeleteRemote, true));
        } else {
          plan.actions.push(this.makeAction(path, ActionType.MkdirLocal, true));
        }
        return;
      }

      if (!localExists && !remoteExists) {
        return;
      }

      if (prev === undefined && localExists && remoteExists) {

        return;
      }

      const localChanged = ChangeDetector.isLocalChanged(localEntry, prev);
      const remoteChanged = ChangeDetector.isRemoteChanged(remoteEntry, prev);

      if (localChanged && remoteChanged) {
        const c = new Conflict();
        c.taskId = task.id;
        c.relPath = path;
        c.localMtime = localEntry !== undefined ? localEntry.mtime : 0;
        c.remoteMtime = remoteEntry !== undefined ? remoteEntry.mtime : 0;
        c.strategy = task.conflictStrategy;
        c.resolved = false;
        plan.conflicts.push(c);
        return;
      }

      if (localChanged && !remoteChanged) {
        if (localExists) {
          if (direction === SyncDirection.Bidirectional || direction === SyncDirection.UploadOnly) {
            plan.actions.push(this.makeAction(path, ActionType.Upload, false));
          }
        } else if (direction === SyncDirection.Bidirectional) {
          plan.actions.push(this.makeAction(path, ActionType.DeleteRemote, false));
        }
        return;
      }

      if (!localChanged && remoteChanged) {
        if (remoteExists) {
          if (direction === SyncDirection.Bidirectional || direction === SyncDirection.DownloadOnly) {
            plan.actions.push(this.makeAction(path, ActionType.Download, false));
          }
        } else if (direction === SyncDirection.Bidirectional) {
          plan.actions.push(this.makeAction(path, ActionType.DeleteLocal, false));
        }
      }
    });
    return plan;
  }

  private makeAction(relPath: string, type: ActionType, isDirectory: boolean): SyncAction {
    const a = new SyncAction();
    a.relPath = relPath;
    a.type = type;
    a.isDirectory = isDirectory;
    return a;
  }

  private isFiltered(filter: FileFilter, path: string): boolean {
    const segs = path.split('/');
    for (const seg of segs) {
      if (seg === '') {
        continue;
      }
      if (filter.matches(seg)) {
        return true;
      }
    }
    return false;
  }

  private async runConcurrent<T>(items: T[], limit: number, worker: (item: T) => Promise<void>): Promise<void> {
    if (items.length === 0) {
      return;
    }
    const n = Math.max(1, Math.min(limit, items.length));
    const batches: T[][] = [];
    for (let i = 0; i < n; i++) {
      batches.push([]);
    }
    for (let i = 0; i < items.length; i++) {
      batches[i % n].push(items[i]);
    }
    const runners: Promise<void>[] = [];
    for (const batch of batches) {
      runners.push(this.runBatch(batch, worker));
    }
    await Promise.all(runners);
  }

  private async runBatch<T>(batch: T[], worker: (item: T) => Promise<void>): Promise<void> {
    for (const item of batch) {
      await worker(item);
    }
  }


  // One line telling the user what this pass is about to do, and in which direction.
  private describePlan(plan: SyncPlan): string {
    let up = 0;
    let down = 0;
    let delLocal = 0;
    let delRemote = 0;
    let mk = 0;
    for (const a of plan.actions) {
      if (a.type === ActionType.Upload) {
        up += 1;
      } else if (a.type === ActionType.Download) {
        down += 1;
      } else if (a.type === ActionType.DeleteLocal) {
        delLocal += 1;
      } else if (a.type === ActionType.DeleteRemote) {
        delRemote += 1;
      } else {
        mk += 1;
      }
    }
    const parts: string[] = [];
    if (up > 0) {
      parts.push('上传 NAS ' + up.toString());
    }
    if (down > 0) {
      parts.push('下载到本地 ' + down.toString());
    }
    if (delRemote > 0) {
      parts.push('本地已删，删 NAS ' + delRemote.toString());
    }
    if (delLocal > 0) {
      parts.push('NAS 已删，删本地 ' + delLocal.toString());
    }
    if (mk > 0) {
      parts.push('新建文件夹 ' + mk.toString());
    }
    if (plan.conflicts.length > 0) {
      parts.push('冲突 ' + plan.conflicts.length.toString());
    }
    return parts.join('  ');
  }

  private async executeRemoteMkdirs(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    for (const a of plan.actions) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      if (a.type !== ActionType.MkdirRemote) {
        continue;
      }
      const res = await this.webDavClient.mkdir(conn, this.remoteRelPath(task, a.relPath));
      if (res.success) {
        const localEntry = localSnap.get(a.relPath);
        if (localEntry !== undefined) {
          remoteSnap.set(a.relPath, localEntry);
        }
      }
      SyncProgressTracker.step(task.id, 'NAS 新建文件夹', a.relPath);
    }
  }

  private async executeLocalMkdirs(task: SyncTask, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    for (const a of plan.actions) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      if (a.type !== ActionType.MkdirLocal) {
        continue;
      }
      // Skip mkdir for paths that already exist
      const fullPath = this.localPathFor(task, a.relPath);
      const exists = await this.localFileService.exists(fullPath);
      if (!exists) {
        const res = await this.localFileService.ensureDir(fullPath);
        if (res.success) {
          const remoteEntry = remoteSnap.get(a.relPath);
          if (remoteEntry !== undefined) {
            localSnap.set(a.relPath, remoteEntry);
          }
        } else {
          hilog.warn(0x0000, 'WebDAVSync', 'executeLocalMkdirs FAIL relPath=%{public}s err=%{public}s', a.relPath, res.errorMessage);
          result.failedCount += 1;
          result.failedPaths.push(a.relPath);
        }
      } else {
        hilog.info(0x0000, 'WebDAVSync', 'executeLocalMkdirs SKIP (exists) relPath=%{public}s', a.relPath);
        const remoteEntry = remoteSnap.get(a.relPath);
        if (remoteEntry !== undefined) {
          localSnap.set(a.relPath, remoteEntry);
        }
      }
      SyncProgressTracker.step(task.id, '本地新建文件夹', a.relPath);
    }
  }

  private async executeUploads(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const actions: SyncAction[] = [];
    for (const a of plan.actions) {
      if (a.type === ActionType.Upload) {
        actions.push(a);
      }
    }
    await this.runConcurrent<SyncAction>(actions, task.concurrency, async (a: SyncAction) => {
      if (this.cancelled.has(task.id)) {
        return;
      }
      const localPath = this.localPathFor(task, a.relPath);
      const res = await this.webDavClient.uploadFile(conn, localPath, this.remoteRelPath(task, a.relPath), () => {});
      if (res.success) {
        result.transferred += 1;
        await this.recordAfterUpload(task, a.relPath, localSnap, remoteSnap);
      } else {
        hilog.info(0x0000, 'WebDAVSync', 'upload FAIL relPath=%{public}s err=%{public}s', a.relPath, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, '上传到 NAS', a.relPath);
    });
  }

  private async executeDownloads(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const actions: SyncAction[] = [];
    for (const a of plan.actions) {
      if (a.type === ActionType.Download) {
        actions.push(a);
      }
    }
    await this.runConcurrent<SyncAction>(actions, task.concurrency, async (a: SyncAction) => {
      if (this.cancelled.has(task.id)) {
        return;
      }
      const localPath = this.localPathFor(task, a.relPath);
      const res = await this.performDownload(conn, task, this.remoteRelPath(task, a.relPath), localPath, a.relPath, localSnap, remoteSnap);
      if (res.success) {
        result.transferred += 1;
      } else {
        hilog.info(0x0000, 'WebDAVSync', 'download FAIL relPath=%{public}s err=%{public}s', a.relPath, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, '从 NAS 下载', a.relPath);
    });
  }

  private async executeRemoteDeletes(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const dirs = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteRemote && a.isDirectory);
    const files = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteRemote && !a.isDirectory);
    for (const a of files) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      const res = await this.webDavClient.deleteItem(conn, this.remoteRelPath(task, a.relPath));
      if (res.success) {
        remoteSnap.delete(a.relPath);
      } else {
        hilog.error(0x0000, 'WebDAVSync', 'deleteRemoteFile FAIL relPath=%{public}s code=%{public}d msg=%{public}s',
          a.relPath, res.errorCode, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, '本地已删文件，删除 NAS', a.relPath);
    }
    for (const a of dirs) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      const res = await this.webDavClient.deleteItem(conn, this.remoteRelPath(task, a.relPath));
      if (res.success) {
        remoteSnap.delete(a.relPath);
      } else {
        hilog.error(0x0000, 'WebDAVSync', 'deleteRemoteDir FAIL relPath=%{public}s code=%{public}d msg=%{public}s',
          a.relPath, res.errorCode, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, '本地已删文件夹，删除 NAS', a.relPath);
    }
  }

  private async executeLocalDeletes(task: SyncTask, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const dirs = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteLocal && a.isDirectory);
    const files = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteLocal && !a.isDirectory);
    for (const a of files) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      hilog.info(0x0000, 'WebDAVSync', 'deleteLocalFile relPath=%{public}s', a.relPath);
      const res = await this.localFileService.removePath(this.localPathFor(task, a.relPath));
      if (res.success) {
        localSnap.delete(a.relPath);
      } else {
        hilog.error(0x0000, 'WebDAVSync', 'deleteLocalFile FAIL relPath=%{public}s code=%{public}d msg=%{public}s',
          a.relPath, res.errorCode, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, 'NAS 已删文件，删除本地', a.relPath);
    }
    for (const a of dirs) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      hilog.info(0x0000, 'WebDAVSync', 'deleteLocalDir relPath=%{public}s', a.relPath);
      const res = await this.localFileService.removePath(this.localPathFor(task, a.relPath));
      if (res.success) {
        localSnap.delete(a.relPath);
      } else {
        hilog.error(0x0000, 'WebDAVSync', 'deleteLocalDir FAIL relPath=%{public}s code=%{public}d msg=%{public}s',
          a.relPath, res.errorCode, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, 'NAS 已删文件夹，删除本地', a.relPath);
    }
  }

  async resolveConflict(task: SyncTask, conflict: Conflict, strategy: ConflictStrategy): Promise<Result<boolean>> {
    const connRes = await this.connectionManager.getById(task.connectionId);
    if (!connRes.success || connRes.data === null) {
      return Result.fail(-1, '连接不存在');
    }
    // applyConflictStrategy stores the resulting file state per file.
    await this.applyConflictStrategy(task, connRes.data, conflict, strategy, new SyncResult(),
      new Map<string, FileEntry>(), new Map<string, FileEntry>());
    await this.syncStore.deleteConflict(task.id, conflict.relPath);
    return Result.ok(true);
  }

  private async applyConflictStrategy(task: SyncTask, conn: Connection, conflict: Conflict, strategy: ConflictStrategy,
    result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const localPath = this.localPathFor(task, conflict.relPath);
    const remoteRel = this.remoteRelPath(task, conflict.relPath);
    if (strategy === ConflictStrategy.KeepLocal) {
      if ((await this.webDavClient.uploadFile(conn, localPath, remoteRel, () => {})).success) {
        result.transferred += 1;
        await this.recordAfterUpload(task, conflict.relPath, localSnap, remoteSnap);
      }
    } else if (strategy === ConflictStrategy.KeepRemote) {
      if ((await this.performDownload(conn, task, remoteRel, localPath, conflict.relPath, localSnap, remoteSnap)).success) {
        result.transferred += 1;
      }
    } else {
      const diff = Math.abs(conflict.localMtime - conflict.remoteMtime);
      if (diff <= LWW_EPSILON) {
        const stamp = Date.now();
        const copyPath = localPath + '.conflict.' + stamp;
        result.localTouched.push(conflict.relPath + '.conflict.' + stamp);
        const statRes = await this.localFileService.stat(localPath);
        if (statRes.success && statRes.data !== null) {
          const data = await this.localFileService.readFileRange(localPath, 0, statRes.data.size);
          if (data.success && data.data !== null) {
            await this.localFileService.writeFile(copyPath, data.data);
          }
        }
        await this.performDownload(conn, task, remoteRel, localPath, conflict.relPath, localSnap, remoteSnap);
        result.transferred += 1;
      } else if (conflict.localMtime > conflict.remoteMtime) {
        if ((await this.webDavClient.uploadFile(conn, localPath, remoteRel, () => {})).success) {
          result.transferred += 1;
          await this.recordAfterUpload(task, conflict.relPath, localSnap, remoteSnap);
        }
      } else {
        if ((await this.performDownload(conn, task, remoteRel, localPath, conflict.relPath, localSnap, remoteSnap)).success) {
          result.transferred += 1;
        }
      }
    }
    await this.syncStore.deleteConflict(task.id, conflict.relPath);
  }

  // Progress is written per file so a paused or killed run resumes with what is left
  // instead of re-transferring the whole vault.
  private async recordAfterUpload(task: SyncTask, relPath: string, localSnap: Map<string, FileEntry>,
    remoteSnap: Map<string, FileEntry>): Promise<void> {
    const stRes = await this.localFileService.stat(this.localPathFor(task, relPath));
    if (!stRes.success || stRes.data === null) {
      return;
    }
    localSnap.set(relPath, stRes.data);
    // Synology answers the PROPFIND right after a PUT with an etag that the next sweep
    // does not repeat, so store no baseline here; the next pass reads it from the sweep.
    remoteSnap.delete(relPath);
    await this.saveState(task, relPath, stRes.data.mtime, '', 0);
  }

  private async recordAfterDownload(task: SyncTask, relPath: string, localSnap: Map<string, FileEntry>,
    remoteSnap: Map<string, FileEntry>): Promise<void> {
    const stRes = await this.localFileService.stat(this.localPathFor(task, relPath));
    if (!stRes.success || stRes.data === null) {
      return;
    }
    // The downloaded file keeps whatever mtime the filesystem gave it; local timestamps
    // are never rewritten.
    localSnap.set(relPath, stRes.data);
    const remoteEntry = remoteSnap.get(relPath);
    await this.saveState(task, relPath, stRes.data.mtime,
      remoteEntry !== undefined ? remoteEntry.etag : '',
      remoteEntry !== undefined ? remoteEntry.mtime : 0);
  }

  private async saveState(task: SyncTask, relPath: string, localMtime: number, remoteEtag: string,
    remoteMtime: number): Promise<void> {
    const state = new FileState();
    state.taskId = task.id;
    state.relPath = relPath;
    state.localMtime = localMtime;
    state.remoteEtag = remoteEtag;
    state.remoteMtime = remoteMtime;
    state.conflict = false;
    await this.syncStore.upsertFileState(state);
  }

  private async performDownload(conn: Connection, task: SyncTask, remoteRel: string, localPath: string,
    relPath: string, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<Result<boolean>> {
    const res = await this.webDavClient.downloadFile(conn, remoteRel, localPath, 0, () => {});
    if (res.success) {
      await this.recordAfterDownload(task, relPath, localSnap, remoteSnap);
    }
    return res;
  }

  // The baseline must end up describing exactly the paths that exist on both sides. Rewriting
  // every row on every pass cost ~2000 single-row SQL transactions per poll even when nothing had
  // changed, which kept the CPU and the flash busy on an idle vault, so only rows that differ are
  // written and only rows whose path is no longer on both sides are dropped.
  private async rebuildFileStates(task: SyncTask, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>, existing: Map<string, FileState>): Promise<void> {
    const toWrite: FileState[] = [];
    localSnap.forEach((localEntry: FileEntry, path: string) => {
      const remoteEntry = remoteSnap.get(path);
      if (remoteEntry === undefined) {
        return;
      }
      const prev = existing.get(path);
      if (prev !== undefined && !prev.conflict && prev.localMtime === localEntry.mtime &&
        prev.remoteMtime === remoteEntry.mtime && prev.remoteEtag === remoteEntry.etag) {
        return;
      }
      toWrite.push(this.makeState(task, path, localEntry, remoteEntry));
    });
    for (const state of toWrite) {
      await this.syncStore.upsertFileState(state);
    }

    const stale: string[] = [];
    existing.forEach((state: FileState) => {
      const path = state.relPath;
      if (!localSnap.has(path) || !remoteSnap.has(path)) {
        stale.push(path);
      }
    });
    for (const path of stale) {
      // A leftover baseline for a path that is gone from both sides turns a later file with the
      // same name into a phantom conflict, so it cannot be kept.
      await this.syncStore.deleteFileState(task.id, path);
    }
    if (toWrite.length > 0 || stale.length > 0) {
      hilog.info(0x0000, 'WebDAVSync', 'baselines: wrote=%{public}d pruned=%{public}d of=%{public}d',
        toWrite.length, stale.length, existing.size);
    }
  }

  // A baseline is only honest for a file that exists on both sides. Recording one for a
  // path whose transfer failed makes the next pass read it as "the remote deleted it" and
  // throw away the local copy.
  private makeState(task: SyncTask, path: string, localEntry: FileEntry, remoteEntry: FileEntry): FileState {
    const state = new FileState();
    state.taskId = task.id;
    state.relPath = path;
    state.localMtime = localEntry.mtime;
    state.remoteEtag = remoteEntry.etag;
    state.remoteMtime = remoteEntry.mtime;
    state.conflict = false;
    return state;
  }
}