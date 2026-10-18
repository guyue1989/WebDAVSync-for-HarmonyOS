export enum SyncDirection {
  UploadOnly = 'upload',
  DownloadOnly = 'download',
  Bidirectional = 'bidirectional'
}

export enum ConflictStrategy {
  KeepLocal = 'keep_local',
  KeepRemote = 'keep_remote',
  CreateCopy = 'create_copy',
  ManualResolve = 'manual'
}

export enum TransferDirection {
  Upload = 'upload',
  Download = 'download'
}

export enum SyncStatus {
  Idle = 'idle',
  Comparing = 'comparing',
  Transferring = 'transferring',
  Resolving = 'resolving',
  Completed = 'completed',
  Paused = 'paused',
  Error = 'error'
}

export enum ChangeType {
  Add = 'add',
  Modify = 'modify',
  Delete = 'delete'
}