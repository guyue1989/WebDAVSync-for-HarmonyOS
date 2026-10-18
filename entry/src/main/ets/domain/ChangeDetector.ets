import { FileEntry } from './FileEntry';
import { FileState } from './FileState';

const MTIME_WINDOW = 2;

export class ChangeDetector {
  static isSameFile(local: FileEntry | undefined, remote: FileEntry | undefined): boolean {
    if (local === undefined || remote === undefined) {
      return false;
    }
    return local.size === remote.size;
  }

  static isLocalChanged(localEntry: FileEntry | undefined, prev: FileState | undefined): boolean {
    if (localEntry !== undefined) {
      if (prev === undefined) {
        return true;
      }
      return Math.abs(localEntry.mtime - prev.localMtime) > MTIME_WINDOW;
    }
    return prev !== undefined;
  }

  static isRemoteChanged(remoteEntry: FileEntry | undefined, prev: FileState | undefined): boolean {
    if (remoteEntry !== undefined) {
      if (prev === undefined) {
        return true;
      }
      // Synology ignores X-OC-Mtime, so a remote file's mtime is its upload time and
      // keeps diverging from the local mtime. Only etag is a trustworthy signal; with
      // no etag on either side treat the file as unchanged instead of re-downloading
      // it forever.
      if (prev.remoteEtag !== '' && remoteEntry.etag !== '') {
        return remoteEntry.etag !== prev.remoteEtag;
      }
      return false;
    }
    return prev !== undefined;
  }
}