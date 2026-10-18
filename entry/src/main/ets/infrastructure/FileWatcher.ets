import { ILocalFileService } from './LocalFileService';
import { FileEntry } from '../domain/FileEntry';
import { ChangeType } from '../domain/Enums';
import { Result } from '../domain/Result';

// While the vault is being edited, local changes have to reach the NAS in about a second, and a
// full recursive snapshot takes a fraction of a second, so one second is the useful interval.
const MIN_POLL_GAP_MS = 1000;
// An idle vault does not need that: a walk stats every entry, and running one per second forever
// keeps a core busy on a folder nobody has touched for hours.
const IDLE_POLL_GAP_MS = 15000;
// A change within this window counts as "being edited" and brings the fast rate back. Note-taking
// that is continuous stays fast; a folder left alone for a minute drops to the slow rate.
const ACTIVE_WINDOW_MS = 60000;

export class FileEvent {
  relPath: string = '';
  type: ChangeType = ChangeType.Modify;
}

export interface IFileWatcher {
  watch(dir: string, debounceMs: number, onEvent: (events: FileEvent[]) => void): Promise<Result<boolean>>;
  pause(): void;
  resume(touched: string[]): Promise<void>;
  stop(): Promise<void>;
}

export class FileWatcher implements IFileWatcher {
  private localFileService: ILocalFileService;
  private dir: string = '';
  private lastSnapshot: Map<string, FileEntry> | null = null;
  private pending: FileEvent[] = [];
  private lastFired: FileEvent[] = [];
  private pollTimer: number = -1;
  private debounceTimer: number = -1;
  private paused: boolean = false;
  private stopped: boolean = false;
  private callback: ((events: FileEvent[]) => void) | null = null;
  private debounceMs: number = 500;
  private lastChangeAt: number = 0;

  constructor(localFileService: ILocalFileService) {
    this.localFileService = localFileService;
  }

  async watch(dir: string, debounceMs: number, onEvent: (events: FileEvent[]) => void): Promise<Result<boolean>> {
    this.dir = dir;
    this.debounceMs = debounceMs;
    this.callback = onEvent;
    // Start in the fast state: whoever just picked or re-picked this folder is about to use it.
    this.lastChangeAt = Date.now();
    const snapshot = await this.localFileService.readSnapshot(dir);
    if (snapshot.success && snapshot.data !== null) {
      this.lastSnapshot = snapshot.data;
    }
    // A folder the app cannot read yet (the grant is re-obtained after a reinstall) must not
    // stop the watcher for good: keep polling and let the first successful walk establish the
    // baseline.
    this.schedulePoll(MIN_POLL_GAP_MS);
    return Result.ok(true);
  }

  // Chained timeouts instead of setInterval: the next walk is only armed once the previous one
  // resolved, so a slow folder cannot pile up concurrent snapshots.
  private schedulePoll(delayMs: number): void {
    if (this.stopped) {
      // A walk or the initial snapshot can still resolve after stop(); it must not re-arm.
      return;
    }
    this.pollTimer = setTimeout(() => {
      this.poll();
    }, delayMs);
  }

  // The measured walk time is the floor: a walk must not overlap the pass it just started.
  // Once the vault has had no change for a while the gap widens, so an untouched folder stops
  // spending every second on snapshot walks.
  private nextGap(walkMs: number): number {
    const floor = walkMs > MIN_POLL_GAP_MS ? walkMs : MIN_POLL_GAP_MS;
    if (Date.now() - this.lastChangeAt < ACTIVE_WINDOW_MS) {
      return floor;
    }
    return floor > IDLE_POLL_GAP_MS ? floor : IDLE_POLL_GAP_MS;
  }

  private poll(): void {
    this.pollTimer = -1;
    if (this.paused) {
      // A pass is up; this only re-checks the flag, it does not touch the folder.
      this.schedulePoll(MIN_POLL_GAP_MS);
      return;
    }
    const started = Date.now();
    this.localFileService.readSnapshot(this.dir).then((res: Result<Map<string, FileEntry>>) => {
      // The walk runs on the UI thread, so on a big vault it waits for itself instead of
      // occupying every second of it; detection latency then tracks how long a walk takes.
      const elapsed = Date.now() - started;
      if (this.paused) {
        this.schedulePoll(MIN_POLL_GAP_MS);
        return;
      }
      this.schedulePoll(this.nextGap(elapsed));
      if (!res.success || res.data === null) {
        return;
      }
      if (this.lastSnapshot === null) {
        this.lastSnapshot = res.data;
        return;
      }
      const events = this.diff(this.lastSnapshot, res.data);
      this.lastSnapshot = res.data;
      if (events.length > 0) {
        // The vault is being edited again: go back to the fast rate for the sync it just started.
        this.lastChangeAt = Date.now();
        this.mergeEvents(events);
        this.scheduleDebounce();
      }
    }, () => {
      this.schedulePoll(this.nextGap(0));
    });
  }

  private diff(oldSnap: Map<string, FileEntry>, newSnap: Map<string, FileEntry>): FileEvent[] {
    const events: FileEvent[] = [];
    newSnap.forEach((entry: FileEntry, path: string) => {
      const old = oldSnap.get(path);
      if (old === undefined) {
        const e = new FileEvent();
        e.relPath = path;
        e.type = ChangeType.Add;
        events.push(e);
      } else if (old.mtime !== entry.mtime || old.size !== entry.size) {
        const e = new FileEvent();
        e.relPath = path;
        e.type = ChangeType.Modify;
        events.push(e);
      }
    });
    oldSnap.forEach((old: FileEntry, path: string) => {
      if (!newSnap.has(path)) {
        const e = new FileEvent();
        e.relPath = path;
        e.type = ChangeType.Delete;
        events.push(e);
      }
    });
    return events;
  }

  private mergeEvents(events: FileEvent[]): void {
    for (const e of events) {
      const idx = this.pending.findIndex((x: FileEvent) => x.relPath === e.relPath);
      if (idx >= 0) {
        this.pending[idx].type = e.type;
      } else {
        this.pending.push(e);
      }
    }
  }

  private scheduleDebounce(): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      const events = this.pending;
      this.pending = [];
      if (this.callback !== null && events.length > 0 && !this.paused) {
        this.lastFired = events;
        this.callback(events);
      }
    }, this.debounceMs);
  }

  pause(): void {
    this.paused = true;
  }

  // Called when the pass this watcher triggered is over. No snapshot walk runs while a pass is
  // up, so everything the folder looks different by now has to be sorted into what the pass
  // itself wrote (touched, plus every folder above it, whose mtime shifts when a child changes)
  // and what already started that pass, versus a change the user made in the meantime. Only the
  // last group re-triggers, which is what keeps a change made mid-pass from waiting for the
  // next slow poll.
  async resume(touched: string[]): Promise<void> {
    if (this.stopped) {
      return;
    }
    try {
      const snapshot = await this.localFileService.readSnapshot(this.dir);
      this.pending = [];
      if (!snapshot.success || snapshot.data === null) {
        return;
      }
      const events: FileEvent[] = this.lastSnapshot === null ? [] : this.diff(this.lastSnapshot, snapshot.data);
      this.lastSnapshot = snapshot.data;

      const skip = new Set<string>();
      for (const e of this.lastFired) {
        skip.add(e.relPath);
      }
      for (const p of touched) {
        // The download staging file of a path the pass wrote is the pass's own work too.
        skip.add(p + '.part');
        let ancestor = '';
        for (const seg of p.split('/')) {
          ancestor = ancestor === '' ? seg : ancestor + '/' + seg;
          skip.add(ancestor);
        }
      }
      const kept: FileEvent[] = [];
      for (const e of events) {
        if (!skip.has(e.relPath)) {
          kept.push(e);
        }
      }
      if (kept.length > 0) {
        this.lastChangeAt = Date.now();
        this.mergeEvents(kept);
        this.scheduleDebounce();
      }
    } finally {
      // Only now: while this bookkeeping ran, a tick must not snapshot the folder behind it.
      this.paused = false;
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.pollTimer !== -1) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    this.lastSnapshot = null;
    this.pending = [];
    this.lastFired = [];
    this.callback = null;
  }
}