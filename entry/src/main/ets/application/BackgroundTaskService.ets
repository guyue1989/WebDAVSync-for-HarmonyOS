import backgroundTaskManager from '@ohos.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { AppContext } from './AppContext';
import { Result } from '../domain/Result';

const BUNDLE_NAME = 'com.niangao.webdavsync';
const TAG = 'WebDAVSync';

// Without one of these held, the system suspends the process as soon as the window is closed to
// the status bar, which stops every timer and leaves the tray icon showing a sync that is asleep.
// taskKeeping is the PC/2in1 background-computation type (open to third-party apps from API 20)
// and carries no progress obligation, which suits a client that is idle between polls.
// dataTransfer is the fallback for builds that refuse it, but the system cancels a transfer task
// once ~10 minutes pass without a live-window progress update, so it is the weaker keepalive.
const KEEPALIVE_MODES: backgroundTaskManager.BackgroundMode[] = [
  backgroundTaskManager.BackgroundMode.TASK_KEEPING,
  backgroundTaskManager.BackgroundMode.DATA_TRANSFER
];

// This SDK build exposes no cancellation event for continuous tasks, so a keepalive taken away by a
// system consistency check or a dismissed notification cannot be observed. Re-asking on a timer
// costs one call per interval and recovers from both cases; the poll tick is what triggers it.
const REASSERT_MS = 5 * 60 * 1000;
// startBackgroundRunning answers this when a continuous task is already running for the app.
const ALREADY_APPLIED = 9800005;

export interface IBackgroundTaskService {
  start(): Promise<Result<boolean>>;
  stop(): Promise<Result<boolean>>;
  reacquire(): Promise<Result<boolean>>;
}

export class BackgroundTaskService implements IBackgroundTaskService {
  private held: boolean = false;
  private lastAttempt: number = 0;

  // Safe to call on every activity: while the task is held this is one boolean test, and a rejected
  // acquisition is retried once per interval rather than on every tick. stop() clears the window so
  // an explicit restart asks again immediately.
  async start(): Promise<Result<boolean>> {
    const now = Date.now();
    if (now - this.lastAttempt < REASSERT_MS) {
      return Result.ok(this.held);
    }
    this.lastAttempt = now;
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return Result.fail(-1, 'context 为空');
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: BUNDLE_NAME,
        abilityName: 'EntryAbility'
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      const agent = await wantAgent.getWantAgent(wantAgentInfo);
      for (const mode of KEEPALIVE_MODES) {
        try {
          await backgroundTaskManager.startBackgroundRunning(ctx, mode, agent);
          this.held = true;
          hilog.info(0x0000, TAG, 'continuous task held, mode=%{public}d', mode);
          return Result.ok(true);
        } catch (e) {
          const err = e as BusinessError;
          if (err.code === ALREADY_APPLIED) {
            // 9800005 with "the application has applied for a continuous task" is not a refusal: the
            // task is held, so asking again is a no-op. Taking it as success keeps the re-ask quiet
            // and stops the fallback mode from being requested on top of a task already running.
            this.held = true;
            hilog.info(0x0000, TAG, 'continuous task already held, mode=%{public}d', mode);
            return Result.ok(true);
          }
          hilog.warn(0x0000, TAG, 'startBackgroundRunning mode=%{public}d rejected code=%{public}d msg=%{public}s',
            mode, err.code, err.message);
        }
      }
      return Result.fail(-1, '后台任务申请失败：没有可用的长时任务类型');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'wantAgent failed code=%{public}d msg=%{public}s', err.code, err.message);
      return Result.fail(-1, '后台任务申请失败');
    }
  }

  async stop(): Promise<Result<boolean>> {
    const ctx = AppContext.getContext();
    this.held = false;
    this.lastAttempt = 0;
    if (ctx === null) {
      return Result.fail(-1, 'context 为空');
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      hilog.info(0x0000, TAG, 'continuous task released');
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'stopBackgroundRunning failed code=%{public}d msg=%{public}s', err.code, err.message);
      return Result.fail(-1, '后台任务停止失败');
    }
  }

  // Ignore the retry window: a foreground return is the one moment where asking again is free, and
  // it is also how a keepalive the user dismissed gets picked back up.
  reacquire(): Promise<Result<boolean>> {
    this.lastAttempt = 0;
    return this.start();
  }
}
