import { SyncDirection } from './Enums';
import { ConflictStrategy } from './Enums';

export class SyncTask {
  id: string = '';
  connectionId: string = '';
  localDir: string = '';
  remoteDir: string = '';
  direction: SyncDirection = SyncDirection.Bidirectional;
  conflictStrategy: ConflictStrategy = ConflictStrategy.CreateCopy;
  watchEnabled: boolean = true;
  debounceMs: number = 500;
  pollIntervalSec: number = 30;
  filterRules: string = '';
  concurrency: number = 2;
}