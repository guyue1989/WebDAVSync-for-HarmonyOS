import { SyncTask } from '../domain/SyncTask';
import { Result } from '../domain/Result';
import { ISyncEngine } from './SyncEngine';
import { ILocalFileService } from '../infrastructure/LocalFileService';
import { FileWatcher } from '../infrastructure/FileWatcher';
import { IFileWatcher } from '../infrastructure/FileWatcher';
import { FileEvent } from '../infrastructure/FileWatcher';
import { INotificationService } from './NotificationService';
import { IBackgroundTaskService } from './BackgroundTaskService';

export interface ISyncScheduler {
  startWatch(task: SyncTask): Promise<Result<boolean>>;
  stopWatch(taskId: string): Promise<void>;
  startPolling(task: SyncTask): Promise<Result<boolean>>;
  stopPolling(taskId: string): Promise<void>;
  stopAll(): Promise<void>;
}

export class SyncScheduler implements ISyncScheduler {
  private localFileService: ILocalFileService;
  private syncEngine: ISyncEngine;
  private notificationService: INotificationService | null;
  private backgroundTaskService: IBackgroundTaskService | null;
  private watchers: Map<string, IFileWatcher> = new Map<string, IFileWatcher>();
  private pollTimers: Map<string, number> = new Map<string, number>();

  constructor(localFileService: ILocalFileService, syncEngine: ISyncEngine, notificationService: INotificationService | null, backgroundTaskService: IBackgroundTaskService | null) {
    this.localFileService = localFileService;
    this.syncEngine = syncEngine;
    this.notificationService = notificationService;
    this.backgroundTaskService = backgroundTaskService;
  }

  async startWatch(task: SyncTask): Promise<Result<boolean>> {
    if (this.watchers.has(task.id)) {
      return Result.ok(true);
    }
    if (!task.watchEnabled) {
      return Result.ok(false);
    }
    const watcher = new FileWatcher(this.localFileService);
    const res = await watcher.watch(task.localDir, task.debounceMs, (events: FileEvent[]) => {
      watcher.pause();
      this.syncEngine.onLocalChange(task, events).then((r) => {
        watcher.resume(r.localTouched).then(() => {
          if (this.notificationService !== null) {
            this.notificationService.notifySyncResult(r);
          }
        });
      });
    });
    if (res.success) {
      this.watchers.set(task.id, watcher);
      this.acquireAlive();
    }
    return res;
  }

  async stopWatch(taskId: string): Promise<void> {
    const watcher = this.watchers.get(taskId);
    if (watcher !== undefined) {
      await watcher.stop();
      this.watchers.delete(taskId);
    }
    await this.maybeRelease();
  }

  async startPolling(task: SyncTask): Promise<Result<boolean>> {
    if (this.pollTimers.has(task.id)) {
      return Result.ok(true);
    }
    // The interval comes from stored settings, so a missing or bogus value must not turn the
    // remote poll into a tight loop. The floor is not just sanity: one poll pass walks every local
    // file and sends one PROPFIND per remote directory, which on a few-thousand-file vault is
    // hundreds of requests. NAS-side changes do not need sub-minute latency.
    const seconds = task.pollIntervalSec >= 30 ? task.pollIntervalSec : 30;
    const timer = setInterval(() => {
      this.ensureAlive();
      this.syncEngine.pullRemoteChanges(task).then((r) => {
        if (this.notificationService !== null) {
          this.notificationService.notifySyncResult(r);
        }
      });
    }, seconds * 1000);
    this.pollTimers.set(task.id, timer);
    this.acquireAlive();
    return Result.ok(true);
  }

  async stopPolling(taskId: string): Promise<void> {
    const timer = this.pollTimers.get(taskId);
    if (timer !== undefined) {
      clearInterval(timer);
      this.pollTimers.delete(taskId);
    }
    await this.maybeRelease();
  }

  // The keepalive can be taken away at any moment — a system consistency check or a dismissed
  // notification — and a suspended process never reaches the next tick to notice, so every tick
  // re-asks. This is the cheap path: while the task is held it costs one timestamp comparison.
  private ensureAlive(): void {
    if (this.backgroundTaskService !== null) {
      this.backgroundTaskService.start();
    }
  }

  // Starting background business is worth an immediate request rather than a throttled one, so the
  // task the user just enabled is not left waiting on the retry window.
  private acquireAlive(): void {
    if (this.backgroundTaskService !== null) {
      this.backgroundTaskService.reacquire();
    }
  }

  // With no watcher and no timer left there is no background business to justify the keepalive,
  // and holding one anyway is exactly what gets the app flagged by the system.
  private async maybeRelease(): Promise<void> {
    if (this.watchers.size === 0 && this.pollTimers.size === 0 && this.backgroundTaskService !== null) {
      await this.backgroundTaskService.stop();
    }
  }

  async stopAll(): Promise<void> {
    const watchIds: string[] = [];
    this.watchers.forEach((v: IFileWatcher, k: string) => {
      watchIds.push(k);
    });
    for (const id of watchIds) {
      await this.stopWatch(id);
    }
    const pollIds: string[] = [];
    this.pollTimers.forEach((v: number, k: string) => {
      pollIds.push(k);
    });
    for (const id of pollIds) {
      await this.stopPolling(id);
    }
    if (this.backgroundTaskService !== null) {
      await this.backgroundTaskService.stop();
    }
  }
}