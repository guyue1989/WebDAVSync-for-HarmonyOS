import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';

import { BusinessError } from '@ohos.base';
import { FileEntry } from '../domain/FileEntry';
import { Result } from '../domain/Result';

export interface ILocalFileService {
  exists(path: string): Promise<boolean>;
  ensureDir(dir: string): Promise<Result<boolean>>;
  stat(path: string): Promise<Result<FileEntry>>;
  readSnapshot(dir: string): Promise<Result<Map<string, FileEntry>>>;
  readFileRange(path: string, offset: number, length: number): Promise<Result<Uint8Array>>;
  appendFile(path: string, data: Uint8Array): Promise<Result<boolean>>;
  writeFile(path: string, data: Uint8Array): Promise<Result<boolean>>;
  atomicReplace(tmpPath: string, targetPath: string): Promise<Result<boolean>>;
  removePath(path: string): Promise<Result<boolean>>;
  listDirectory(dir: string): Promise<Result<FileEntry[]>>;

  joinPath(...parts: string[]): string;
}

export class LocalFileService implements ILocalFileService {
  // DocumentViewPicker returns URIs like file://docs/storage/Users/currentUser/xxx.
  // URI parsing would drop everything after '#' in a file name, so strip the
  // scheme+authority literally and always work with plain filesystem paths.
  toPath(path: string): string {
    if (!path.startsWith('file://')) {
      return path;
    }
    const rest = path.substring(7);
    const slash = rest.indexOf('/');
    if (slash < 0) {
      return '/';
    }
    return rest.substring(slash);
  }

  joinPath(...parts: string[]): string {
    let result = '';
    for (let p of parts) {
      if (p === '' || p === '/' || p === '.') {
        continue;
      }
      if (result === '') {
        result = p;
      } else {
        result = result.replace(/\/+$/, '') + '/' + p.replace(/^\/+/, '');
      }
    }
    if (!result.startsWith('/')) {
      result = '/' + result;
    }
    return result;
  }

  private relativize(base: string, full: string): string {
    const b = base.replace(/\/+$/, '');
    if (full === b) {
      return '';
    }
    if (full.startsWith(b + '/')) {
      return full.substring(b.length + 1);
    }
    return full;
  }

  async exists(path: string): Promise<boolean> {
    try {
      await fs.access(this.toPath(path));
      return true;
    } catch (e) {
      return false;
    }
  }

  async ensureDir(dir: string): Promise<Result<boolean>> {
    try {
      const p = this.toPath(dir);
      await fs.mkdir(p, true);
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 13400004) {
        return Result.ok(true);
      }
      return Result.fail(err.code, err.message);
    }
  }

  async stat(path: string): Promise<Result<FileEntry>> {
    try {
      const p = this.toPath(path);
      const name = p.substring(p.lastIndexOf('/') + 1);
      const st = await fs.stat(p);
      const isDir = st.isDirectory();
      return Result.ok(new FileEntry(name, isDir, isDir ? 0 : st.size, st.mtime, ''));
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async listDirectory(dir: string): Promise<Result<FileEntry[]>> {
    try {
      const p = this.toPath(dir);
      const names = await fs.listFile(p);
      const entries: FileEntry[] = [];
      for (const name of names) {
        const st = await fs.stat(this.joinPath(p, name));
        const isDir = st.isDirectory();
        entries.push(new FileEntry(name, isDir, isDir ? 0 : st.size, st.mtime, ''));
      }
      return Result.ok(entries);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async readSnapshot(dir: string): Promise<Result<Map<string, FileEntry>>> {
    const map = new Map<string, FileEntry>();
    const p = this.toPath(dir);
    try {
      // fs.access passes even when the folder grant is gone; listing is the real test.
      await fs.listFile(p);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'WebDAVSync', 'readSnapshot FAIL dir=%{public}s code=%{public}d msg=%{public}s',
        p, err.code, err.message);
      return Result.fail(err.code, '无法读取本地目录，请重新选择文件夹: ' + p);
    }
    try {
      await this.walk(p, p, map);
      hilog.info(0x0000, 'WebDAVSync', 'readSnapshot dir=%{public}s entries=%{public}d', p, map.size);
      return Result.ok(map);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  private async walk(dir: string, base: string, result: Map<string, FileEntry>): Promise<void> {
    let names: string[] = [];
    try {
      names = await fs.listFile(dir);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, 'WebDAVSync', 'walk listFile FAIL dir=%{public}s code=%{public}d msg=%{public}s',
        dir, err.code, err.message);
      return;
    }
    for (const name of names) {
      const full = this.joinPath(dir, name);
      const rel = this.relativize(base, full);
      try {
        const st = await fs.stat(full);
        if (st.isDirectory()) {
          result.set(rel, new FileEntry(name, true, 0, st.mtime, ''));
          await this.walk(full, base, result);
        } else {
          result.set(rel, new FileEntry(name, false, st.size, st.mtime, ''));
        }
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(0x0000, 'WebDAVSync', 'walk stat FAIL full=%{public}s code=%{public}d msg=%{public}s',
          full, err.code, err.message);
        continue;
      }
    }
  }

  async readFileRange(path: string, offset: number, length: number): Promise<Result<Uint8Array>> {
    try {
      const file = await fs.open(this.toPath(path), fs.OpenMode.READ_ONLY);
      try {
        if (length === 0) {
          return Result.ok(new Uint8Array(0));
        }
        const buf = new ArrayBuffer(length);
        const readLen = await fs.read(file.fd, buf, { offset: offset, length: length });
        return Result.ok(new Uint8Array(buf, 0, readLen));
      } finally {
        await fs.close(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async writeFile(path: string, data: Uint8Array): Promise<Result<boolean>> {
    try {
      const file = await fs.open(this.toPath(path), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        if (data.length > 0) {
          await fs.write(file.fd, data.buffer as ArrayBuffer);
        }
        return Result.ok(true);
      } finally {
        await fs.close(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async appendFile(path: string, data: Uint8Array): Promise<Result<boolean>> {
    try {
      const file = await fs.open(this.toPath(path), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
      try {
        await fs.write(file.fd, data.buffer as ArrayBuffer);
        return Result.ok(true);
      } finally {
        await fs.close(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async atomicReplace(tmpPath: string, targetPath: string): Promise<Result<boolean>> {
    try {
      await fs.rename(this.toPath(tmpPath), this.toPath(targetPath));
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async removePath(path: string): Promise<Result<boolean>> {
    try {
      const p = this.toPath(path);
      // A directory delete already removes everything below it, and the plan still lists the
      // descendants separately, so "already gone" is a success rather than a failure.
      if (!await fs.access(p)) {
        return Result.ok(true);
      }
      const st = await fs.stat(p);
      if (st.isDirectory()) {
        const names = await fs.listFile(p);
        for (const n of names) {
          await this.removePath(this.joinPath(p, n));
        }
        await fs.rmdir(p);
      } else {
        await fs.unlink(p);
      }
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }
}
