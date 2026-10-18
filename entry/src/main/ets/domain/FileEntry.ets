export class FileEntry {
  name: string = '';
  isDirectory: boolean = false;
  size: number = 0;
  mtime: number = 0;
  etag: string = '';

  constructor(name: string = '', isDirectory: boolean = false, size: number = 0, mtime: number = 0, etag: string = '') {
    this.name = name;
    this.isDirectory = isDirectory;
    this.size = size;
    this.mtime = mtime;
    this.etag = etag;
  }
}