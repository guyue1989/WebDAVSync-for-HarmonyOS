import { ChangeType } from './Enums';
import { FileEntry } from './FileEntry';

export class FileChange {
  relPath: string = '';
  changeType: ChangeType = ChangeType.Modify;
  localEntry: FileEntry | null = null;
  remoteEntry: FileEntry | null = null;
}

export class ChangeSet {
  changes: FileChange[] = [];

  add(change: FileChange): void {
    this.changes.push(change);
  }

  get total(): number {
    return this.changes.length;
  }

  filterByType(type: ChangeType): FileChange[] {
    const result: FileChange[] = [];
    for (const c of this.changes) {
      if (c.changeType === type) {
        result.push(c);
      }
    }
    return result;
  }
}