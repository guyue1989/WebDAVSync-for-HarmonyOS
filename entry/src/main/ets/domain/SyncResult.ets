import { SyncStatus } from './Enums';
import { Conflict } from './Conflict';

export class SyncResult {
  taskId: string = '';
  status: SyncStatus = SyncStatus.Idle;
  busy: boolean = false;
  transferred: number = 0;
  failedCount: number = 0;
  failedPaths: string[] = [];
  conflicts: Conflict[] = [];
  // Relative paths this pass wrote, renamed or removed locally.
  localTouched: string[] = [];
  message: string = '';
}