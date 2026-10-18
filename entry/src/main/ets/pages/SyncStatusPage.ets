import router from '@ohos.router';
import { ServiceContainer } from '../application/ServiceContainer';
import { SyncTask } from '../domain/SyncTask';
import { Conflict } from '../domain/Conflict';
import { SyncProgressTracker } from '../application/SyncProgressTracker';
import { Theme } from '../application/Theme';


@Entry
@Component
struct SyncStatusPage {
  @State tasks: SyncTask[] = [];
  @State conflicts: Conflict[] = [];
  @State lastMessage: string = '';
  @State progressText: string = '';
  @State progressSummary: string = '';
  @State progressVisible: boolean = false;
  @State displayRows: string[] = ['', '', '', '', ''];
  @State anyPaused: boolean = false;
  @StorageProp('themeMode') themeMode: string = 'system';
  @StorageProp('systemDark') systemDark: boolean = false;
  private timerId: number = -1;
  private doneTimerId: number = -1;
  private wasRunning: boolean = false;

  private isDark(): boolean {
    return this.themeMode === 'dark' || (this.themeMode === 'system' && this.systemDark);
  }

  @State private hovBtn: string = '';

  // The status line is a notice, not a log: it shows for 10 seconds and then clears.
  private flash(message: string): void {
    this.lastMessage = message;
    if (this.doneTimerId !== -1) {
      clearTimeout(this.doneTimerId);
    }
    this.doneTimerId = setTimeout(() => {
      this.lastMessage = '';
      this.doneTimerId = -1;
    }, 10000);
  }

  // Paths in a vault are long and the interesting part is the file name, so the middle goes.
  private shorten(line: string): string {
    if (line.length <= 56) {
      return line;
    }
    return line.substring(0, 22) + '…' + line.substring(line.length - 32);
  }

  async aboutToAppear(): Promise<void> {
    await ServiceContainer.init();
    await this.load();
  }

  onPageShow(): void {
    this.timerId = setInterval(() => {
      const snap = SyncProgressTracker.snapshot();
      if (snap.running) {
        if (snap.total === 0 && snap.quiet) {
          // A background poll is still comparing, and it usually finds nothing. Showing
          // '检查变更…' every 30 seconds is noise, so it stays silent until the plan has work.
          return;
        }
        this.wasRunning = true;
        let text = this.progressText;
        let summary = this.progressSummary;
        if (snap.total === 0) {
          // Compare phase: nothing to count yet, but the user must see the pass started.
          summary = '';
          text = snap.summary;
        } else {
          summary = snap.summary;
          const action = snap.currentAction === '' ? '同步中' : snap.currentAction;
          text = action + ' ' + snap.done.toString() + '/' + snap.total.toString() + '  ' + this.shorten(snap.currentFile);
        }
        const rows: string[] = [];
        const recent = snap.recentFiles;
        for (let i = 0; i < 5; i++) {
          if (i < recent.length) {
            rows.push(this.shorten(recent[recent.length - 1 - i]));
          } else {
            rows.push('');
          }
        }
        let rowsChanged = false;
        for (let i = 0; i < 5; i++) {
          if (this.displayRows[i] !== rows[i]) {
            rowsChanged = true;
          }
        }
        // This tick runs twice a second and every @State write re-renders the page, so on a PC that
        // is enough work on its own to keep a core awake during a long transfer. Only the values
        // that actually differ may be written.
        if (rowsChanged) {
          this.displayRows = rows;
        }
        if (this.progressText !== text) {
          this.progressText = text;
        }
        if (this.progressSummary !== summary) {
          this.progressSummary = summary;
        }
        if (!this.progressVisible) {
          this.progressVisible = true;
        }
        if (this.anyPaused) {
          this.anyPaused = false;
        }
        if (this.lastMessage !== '') {
          this.lastMessage = '';
        }
        return;
      }
      let paused = false;
      for (const t of this.tasks) {
        if (ServiceContainer.syncEngine.isPaused(t.id)) {
          paused = true;
        }
      }
      this.anyPaused = paused;
      if (paused && snap.total > 0) {
        // Keep the counters visible: they show how far the paused pass got.
        if (!this.progressVisible) {
          this.progressVisible = true;
        }
        const pausedText = '已暂停 ' + snap.done.toString() + '/' + snap.total.toString();
        if (this.progressText !== pausedText) {
          this.progressText = pausedText;
        }
      } else {
        if (this.progressVisible) {
          this.progressVisible = false;
        }
        if (this.wasRunning) {
          // Covers passes this page did not start: startup, polling and file-watch triggers.
          this.wasRunning = false;
          // A poll pass that found nothing to do compared and finished; saying "同步完成" for
          // it every 30 seconds would be noise.
          if (snap.worked) {
            this.flash('同步完成');
          }
        }
      }
    }, 500);
  }

  onPageHide(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.doneTimerId !== -1) {
      clearTimeout(this.doneTimerId);
      this.doneTimerId = -1;
    }
    this.wasRunning = false;
  }

  async load(): Promise<void> {
    const res = await ServiceContainer.taskManager.list();
    if (res.success && res.data !== null) {
      this.tasks = res.data;
    }
    const allConflicts: Conflict[] = [];
    for (const t of this.tasks) {
      const cr = await ServiceContainer.syncStore.listConflicts(t.id);
      if (cr.success && cr.data !== null) {
        for (const c of cr.data) {
          allConflicts.push(c);
        }
      }
    }
    this.conflicts = allConflicts;
  }

  async runAll(): Promise<void> {
    this.lastMessage = '';
    this.anyPaused = false;
    let msg = '';
    for (const t of this.tasks) {
      const result = await ServiceContainer.syncEngine.startSync(t);
      if (msg === '') {
        msg = result.message;
      }
    }
    // The pass is over, so the tick must not flash a second, plainer notice for it.
    this.wasRunning = false;
    this.flash(msg === '' ? '同步完成' : msg);
    await this.load();
  }

  // Pause only stops the current pass; the per-file progress already stored means the
  // next 立即同步 transfers just what is left.
  async pauseAll(): Promise<void> {
    for (const t of this.tasks) {
      await ServiceContainer.syncEngine.pauseSync(t.id);
    }
    this.anyPaused = true;
    this.flash('已暂停，点“立即同步全部”继续剩余项');
  }

  // fileStates can hold mtimes recorded while a snapshot was empty, which makes every
  // file look modified on both sides. Clearing them makes the next pass treat files
  // present on both sides as already synced and only transfer the one-sided ones.
  async resetStates(): Promise<void> {
    for (const t of this.tasks) {
      await ServiceContainer.syncStore.clearTaskStates(t.id);
    }
    this.flash('已重置 ' + this.tasks.length.toString() + ' 个任务的同步记录，下次同步将重新比对');
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(14).opacity(this.hovBtn === 'back' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'back' : ''; })
          .onClick(() => { router.back(); })
        Text('同步状态').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark())).margin({ left: 8 })
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)

      Row() {
        Button('立即同步全部').fontSize(13).opacity(this.hovBtn === 'run-all' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'run-all' : ''; })
          .onClick(() => { this.runAll(); })
        Button(this.anyPaused ? '已暂停' : '暂停同步').fontSize(13).margin({ left: 10 }).opacity(this.hovBtn === 'pause' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'pause' : ''; })
          .onClick(() => { this.pauseAll(); })
        Button('重置同步记录').fontSize(13).backgroundColor(Theme.sub(this.isDark())).margin({ left: 10 }).opacity(this.hovBtn === 'reset' ? 0.85 : 1)
          .onHover((h: boolean) => { this.hovBtn = h ? 'reset' : ''; })
          .onClick(() => { this.resetStates(); })
      }
      .width('90%')
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 12 })

      if (this.progressVisible) {
        Column() {
          Row() {
            LoadingProgress().width(20).height(20).margin({ right: 8 })
            Text(this.progressText).fontSize(13).fontColor(Theme.primary(this.isDark())).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }
          .width('100%')
          .margin({ bottom: 4 })

          if (this.progressSummary !== '') {
            Text(this.progressSummary).fontSize(12).fontColor(Theme.sub(this.isDark())).margin({ bottom: 8 })
          }

          ForEach(this.displayRows, (row: string, idx: number) => {
            Row() {
              Text(row === '' ? '—' : row).fontSize(12).fontColor(idx === 0 ? Theme.primary(this.isDark()) : Theme.sub(this.isDark())).layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          }, (row: string, idx: number) => idx.toString())
        }
        .width('90%')
        .margin({ bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }

      if (this.lastMessage !== '') {
        Text(this.lastMessage).fontSize(14).fontColor(Theme.primary(this.isDark())).margin({ bottom: 12 })
      }
      Text('冲突列表').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.fg(this.isDark())).width('90%').margin({ bottom: 8 })
      List() {
        ForEach(this.conflicts, (c: Conflict) => {
          ListItem() {
            Text(c.relPath + '（' + c.strategy + '）').fontSize(14).fontColor(Theme.fg(this.isDark())).padding(12)
          }
        }, (c: Conflict) => c.taskId + '/' + c.relPath)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }

}
