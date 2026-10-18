export class FileState {
  taskId: string = '';
  relPath: string = '';
  localMtime: number = 0;
  remoteMtime: number = 0;
  remoteEtag: string = '';
  localHash: string = '';
  conflict: boolean = false;
}