import { ConflictStrategy } from './Enums';

export class Conflict {
  taskId: string = '';
  relPath: string = '';
  localMtime: number = 0;
  remoteMtime: number = 0;
  strategy: ConflictStrategy = ConflictStrategy.CreateCopy;
  resolved: boolean = false;
}