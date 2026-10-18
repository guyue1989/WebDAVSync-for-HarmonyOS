class ProgressSession {
  total: number = 0;
  done: number = 0;
  summary: string = '';
  currentAction: string = '';
  currentFile: string = '';
  recentFiles: string[] = [];
  worked: boolean = false;
  running: boolean = false;
  // A timer-driven background compare nobody asked for; it only becomes visible once it
  // turns out there is work to report.
  quiet: boolean = false;
}

export class ProgressSnapshot {
  running: boolean = false;
  total: number = 0;
  done: number = 0;
  summary: string = '';
  currentAction: string = '';
  currentFile: string = '';
  recentFiles: string[] = [];
  worked: boolean = false;
  quiet: boolean = false;
}

export class SyncProgressTracker {
  private static activeId: string = '';
  private static sessions: Map<string, ProgressSession> = new Map<string, ProgressSession>();
  private static readonly MAX_RECENT = 20;

  static begin(sessionId: string, total: number, summary: string, quiet: boolean): void {
    let s = SyncProgressTracker.sessions.get(sessionId);
    if (s === undefined) {
      s = new ProgressSession();
      SyncProgressTracker.sessions.set(sessionId, s);
    }
    if (!s.running) {
      s.total = total;
      s.done = 0;
      s.summary = summary;
      s.currentAction = '';
      s.currentFile = '';
      s.recentFiles = [];
      s.worked = total > 0;
      s.running = true;
      s.quiet = quiet;
    }
    SyncProgressTracker.activeId = sessionId;
  }

  // A pass opens with a compare phase that has no counter yet, so the plan replaces the
  // placeholder label once the number of actions is known.
  static update(sessionId: string, total: number, summary: string): void {
    const s = SyncProgressTracker.sessions.get(sessionId);
    if (s === undefined) {
      return;
    }
    s.total = total;
    s.done = 0;
    s.summary = summary;
    if (total > 0) {
      s.worked = true;
      // There is work now, so this pass is worth showing even if it started as a background poll.
      s.quiet = false;
    }
    SyncProgressTracker.activeId = sessionId;
  }

  // The action label is what the user reads: the same counter is meaningless when it is
  // unclear whether the engine is uploading, downloading or deleting on either side.
  static step(sessionId: string, action: string, currentFile: string): void {
    const s = SyncProgressTracker.sessions.get(sessionId);
    if (s === undefined) {
      return;
    }
    s.done += 1;
    s.worked = true;
    s.currentAction = action;
    s.currentFile = currentFile;
    s.recentFiles.push(action + '  ' + currentFile);
    if (s.recentFiles.length > SyncProgressTracker.MAX_RECENT) {
      s.recentFiles.splice(0, s.recentFiles.length - SyncProgressTracker.MAX_RECENT);
    }
    SyncProgressTracker.activeId = sessionId;
  }

  static finish(sessionId: string): void {
    const s = SyncProgressTracker.sessions.get(sessionId);
    if (s !== undefined) {
      s.running = false;
    }
  }

  static snapshot(): ProgressSnapshot {
    const snap = new ProgressSnapshot();
    const s = SyncProgressTracker.sessions.get(SyncProgressTracker.activeId);
    if (s === undefined) {
      return snap;
    }
    snap.running = s.running;
    snap.total = s.total;
    snap.done = s.done;
    snap.summary = s.summary;
    snap.currentAction = s.currentAction;
    snap.currentFile = s.currentFile;
    snap.recentFiles = s.recentFiles.slice();
    snap.worked = s.worked;
    snap.quiet = s.quiet;
    return snap;
  }
}