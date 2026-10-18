import http from '@ohos.net.http';
import { util } from '@kit.ArkTS';
import { Connection } from '../domain/Connection';
import { FileEntry } from '../domain/FileEntry';
import { LongNameMapper } from '../domain/LongNameMapper';
import { Result } from '../domain/Result';
import { ISecureStore } from './SecureStore';
import { ILocalFileService } from './LocalFileService';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';

const CHUNK_SIZE = 4 * 1024 * 1024;

// resolveAddress runs at the start of every pass, but connections are reloaded from storage each
// time so conn.activeUrl is always empty here: without a cache every poll pays a fresh probe,
// which on a self-signed NAS is a doomed TLS handshake every 30 seconds and off-LAN a 5 second
// stall. The choice is remembered instead and re-probed after this interval, or at once when a
// pass reports that the address it used is dead.
const RESOLVE_TTL_MS = 300000;

type ProgressCallback = (transferred: number, total: number) => void;

export class FileMeta {
  etag: string = '';
  mtime: number = 0;
}

class ResolvedAddress {
  url: string = '';
  at: number = 0;
}

export interface IWebDavClient {
  testConnection(conn: Connection): Promise<Result<boolean>>;
  resolveAddress(conn: Connection): Promise<Result<boolean>>;
  invalidateAddress(connId: string): void;
  listDirectory(conn: Connection, relativePath: string): Promise<Result<FileEntry[]>>;
  getETag(conn: Connection, relativePath: string): Promise<Result<string>>;
  getFileMeta(conn: Connection, relativePath: string): Promise<Result<FileMeta>>;
  downloadFile(conn: Connection, relativePath: string, localPath: string, resumeOffset: number, onProgress: ProgressCallback): Promise<Result<boolean>>;
  uploadFile(conn: Connection, localPath: string, relativePath: string, onProgress: ProgressCallback): Promise<Result<boolean>>;
  deleteItem(conn: Connection, relativePath: string): Promise<Result<boolean>>;
  mkdir(conn: Connection, relativePath: string): Promise<Result<boolean>>;
  getRemoteSize(conn: Connection, relativePath: string): Promise<Result<number>>;
}

export class WebDavClient implements IWebDavClient {
  private httpClient: http.HttpRequest;
  private secureStore: ISecureStore;
  private localFileService: ILocalFileService;
  private base64: util.Base64Helper = new util.Base64Helper();
  private resolved: Map<string, ResolvedAddress> = new Map<string, ResolvedAddress>();

  constructor(secureStore: ISecureStore, localFileService: ILocalFileService) {
    this.httpClient = http.createHttp();
    this.secureStore = secureStore;
    this.localFileService = localFileService;
  }

  private encodeFullPath(path: string): string {
    const segs = path.split('/');
    const encoded = segs.map((s: string) => encodeURIComponent(s));
    return encoded.join('/');
  }

  private joinRemotePath(root: string, relative: string): string {
    let rootPath = root === '' ? '/' : root;
    if (!rootPath.startsWith('/')) {
      rootPath = '/' + rootPath;
    }
    let rel = relative === '' || relative === '/' ? '' : relative;
    if (rel !== '' && !rel.startsWith('/')) {
      rel = '/' + rel;
    }
    const joined = rootPath.replace(/\/+$/, '') + rel;
    return joined === '' ? '/' : joined;
  }

  private buildUrl(conn: Connection, relativePath: string): string {
    const base = (conn.activeUrl !== '' ? conn.activeUrl : conn.baseUrl).replace(/\/+$/, '');
    const fullPath = this.joinRemotePath(conn.rootPath, relativePath);
    return base + this.encodeFullPath(fullPath);
  }

  async resolveAddress(conn: Connection): Promise<Result<boolean>> {
    if (conn.activeUrl !== '') {
      return Result.ok(true);
    }
    const now = Date.now();
    const hit = this.resolved.get(conn.id);
    if (hit !== undefined && now - hit.at < RESOLVE_TTL_MS) {
      conn.activeUrl = hit.url;
      return Result.ok(true);
    }
    if (conn.lanUrl !== '') {
      const lanOk = await this.probeUrl(conn, conn.lanUrl);
      if (lanOk) {
        conn.activeUrl = conn.lanUrl;
        this.remember(conn.id, conn.activeUrl, now);
        return Result.ok(true);
      }
    }
    conn.activeUrl = conn.wanUrl !== '' ? conn.wanUrl : conn.baseUrl;
    this.remember(conn.id, conn.activeUrl, now);
    return Result.ok(true);
  }

  invalidateAddress(connId: string): void {
    this.resolved.delete(connId);
  }

  private remember(connId: string, url: string, at: number): void {
    const entry = new ResolvedAddress();
    entry.url = url;
    entry.at = at;
    this.resolved.set(connId, entry);
  }

  private async probeUrl(conn: Connection, url: string): Promise<boolean> {
    try {
      const auth = await this.getAuth(conn);
      const probePath = url.replace(/\/+$/, '') + this.encodeFullPath(this.joinRemotePath(conn.rootPath, '/'));
      const resp = await this.httpClient.request(probePath, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 5000,
        connectTimeout: 5000
      });
      return resp.responseCode > 0;
    } catch (e) {
      return false;
    }
  }

  private async getAuth(conn: Connection): Promise<string> {
    const res = await this.secureStore.loadCredential(conn.credentialRef);
    if (!res.success || res.data === null) {
      return '';
    }
    const token = conn.username + ':' + res.data;
    const encoded = this.base64.encodeToStringSync(new util.TextEncoder().encodeInto(token));
    return 'Basic ' + encoded;
  }

  private info<T>(msg: string): Result<T> {
    return Result.fail(0, msg);
  }

  private basename(path: string): string {
    const trimmed = path.replace(/\/+$/, '');
    const idx = trimmed.lastIndexOf('/');
    return idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
  }

  private safeDecode(s: string): string {
    try {
      return decodeURIComponent(s);
    } catch (e) {
      return s;
    }
  }

  async testConnection(conn: Connection): Promise<Result<boolean>> {
    try {
      await this.resolveAddress(conn);
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, '/');
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 30000
      });
      const code = resp.responseCode;
      if (code === 401 || code === 403) {
        return Result.fail(code, '认证失败，请检查账号/密码');
      }
      return Result.ok((code >= 200 && code < 300) || code === 207);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, '请求异常：' + err.message);
    }
  }

  async listDirectory(conn: Connection, relativePath: string): Promise<Result<FileEntry[]>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '1',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 60000,
        connectTimeout: 30000
      });
      if (resp.responseCode !== 207 && !(resp.responseCode >= 200 && resp.responseCode < 300)) {
        return Result.fail(resp.responseCode, '列目录失败');
      }
      const xml = resp.result as string;
      const selfPath = this.joinRemotePath(conn.rootPath, relativePath);
      return Result.ok(this.parseListXml(xml, selfPath));
    } catch (e) {
      return Result.fail(-1, '列目录异常');
    }
  }

  private extractTag(block: string, tag: string): string {
    const re = new RegExp('<[^>]*' + tag + '[^>]*>([\\s\\S]*?)<\\/[^>]*' + tag + '>', 'i');
    const m = re.exec(block);
    return m ? m[1].trim() : '';
  }

  private decodeXmlEntities(s: string): string {
    return s
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'");
  }

  private parseHttpDate(str: string): number {
    const s = str.trim();
    let m = /(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/.exec(s);
    if (m !== null) {
      return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])) / 1000;
    }
    m = /(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})/.exec(s);
    if (m !== null) {
      const months: string[] = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
      const month = months.indexOf(m[2].toLowerCase());
      if (month >= 0) {
        return Date.UTC(Number(m[3]), month, Number(m[1]), Number(m[4]), Number(m[5]), Number(m[6])) / 1000;
      }
    }
    const parsed = Date.parse(s);
    if (!Number.isNaN(parsed)) {
      return parsed / 1000;
    }
    return 0;
  }

  private parseListXml(xml: string, selfPath: string): FileEntry[] {
    const entries: FileEntry[] = [];
    const selfDecoded = this.safeDecode(selfPath).replace(/\/+$/, '');
    const blocks = xml.split(/<\/[^>]*response[^>]*>/i);
    for (const part of blocks) {
      const startIdx = part.search(/<[^>]*response[^>]*>/i);
      if (startIdx < 0) {
        continue;
      }
      const tagEnd = part.indexOf('>', startIdx);
      if (tagEnd < 0) {
        continue;
      }
      const block = part.substring(tagEnd + 1);
      const href = this.decodeXmlEntities(this.extractTag(block, 'href'));
      const hrefDecoded = this.safeDecode(href).replace(/\/+$/, '');
      if (hrefDecoded === selfDecoded) {
        continue;
      }
      const isCollection = /collection/i.test(block);
      const displayName = this.decodeXmlEntities(this.extractTag(block, 'displayname'));
      const lengthStr = this.extractTag(block, 'getcontentlength');
      const mtimeStr = this.extractTag(block, 'getlastmodified');
      const etag = this.extractTag(block, 'getetag');
      const name = displayName !== '' ? displayName : this.basename(this.safeDecode(href));
      const size = lengthStr !== '' ? Number(lengthStr) : 0;
      const mtime = mtimeStr !== '' ? this.parseHttpDate(mtimeStr) : 0;
      entries.push(new FileEntry(name, isCollection, size, mtime, etag));
    }
    return entries;
  }

  async getETag(conn: Connection, relativePath: string): Promise<Result<string>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: http.RequestMethod.HEAD,
        header: { 'Authorization': auth },
        readTimeout: 30000,
        connectTimeout: 30000
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        const h = resp.header as Record<string, string>;
        return Result.ok(h['etag'] ?? h['ETag'] ?? '');
      }
      return Result.fail(resp.responseCode, '获取 ETag 失败');
    } catch (e) {
      return Result.fail(-1, '获取 ETag 异常');
    }
  }

  async getFileMeta(conn: Connection, relativePath: string): Promise<Result<FileMeta>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 30000
      });
      if (resp.responseCode === 207 || (resp.responseCode >= 200 && resp.responseCode < 300)) {
        const xml = resp.result as string;
        const meta = new FileMeta();
        meta.etag = this.extractTag(xml, 'getetag');
        const lastMod = this.extractTag(xml, 'getlastmodified');
        meta.mtime = lastMod !== '' ? this.parseHttpDate(lastMod) : 0;
        return Result.ok(meta);
      }
      return Result.fail(resp.responseCode, '获取文件元信息失败');
    } catch (e) {
      return Result.fail(-1, '获取文件元信息异常');
    }
  }

  async getRemoteSize(conn: Connection, relativePath: string): Promise<Result<number>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 30000
      });
      if (resp.responseCode === 207 || (resp.responseCode >= 200 && resp.responseCode < 300)) {
        const xml = resp.result as string;
        const lenStr = this.extractTag(xml, 'getcontentlength');
        return Result.ok(lenStr !== '' ? Number(lenStr) : 0);
      }
      return Result.fail(resp.responseCode, '获取文件大小失败');
    } catch (e) {
      return Result.fail(-1, '获取文件大小异常');
    }
  }

  // A half-written staging file is dead weight: every later attempt starts from offset 0, and a
  // stray note in the vault is confusing even though the plan now ignores it.
  private async discardPart(partPath: string): Promise<void> {
    const statRes = await this.localFileService.stat(partPath);
    // removePath recurses into a folder, and a staging path is only ever this download's own file,
    // so a folder someone really named <target>.part is left alone.
    if (statRes.success && statRes.data !== null && !statRes.data.isDirectory) {
      await this.localFileService.removePath(partPath);
    }
  }

  async downloadFile(conn: Connection, relativePath: string, localPath: string, resumeOffset: number, onProgress: ProgressCallback): Promise<Result<boolean>> {
    const partPath = LongNameMapper.withSuffix(localPath, '.part');
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const sizeRes = await this.getRemoteSize(conn, relativePath);
      if (!sizeRes.success || sizeRes.data === null) {
        // Also clears a staging file a killed process left for a target the NAS no longer has,
        // which would otherwise sit in the vault forever.
        await this.discardPart(partPath);
        return Result.fail(-1, '无法获取远端文件大小');
      }
      const total = sizeRes.data;
      const lastSlash = localPath.lastIndexOf('/');
      if (lastSlash > 0) {
        // Empty files used to return before this point, so their parent folder was never
        // created and the write failed on a path that did not exist yet.
        await this.localFileService.ensureDir(localPath.substring(0, lastSlash));
      }
      if (total === 0) {
        const emptyRes = await this.localFileService.writeFile(localPath, new Uint8Array(0));
        if (!emptyRes.success) {
          return Result.fail(-1, '写入空文件失败：' + emptyRes.errorMessage);
        }
        onProgress(0, 0);
        return Result.ok(true);
      }
      let offset = resumeOffset;
      while (offset < total) {
        const end = Math.min(offset + CHUNK_SIZE - 1, total - 1);
        const resp = await this.httpClient.request(url, {
          method: http.RequestMethod.GET,
          header: {
            'Authorization': auth,
            'Range': 'bytes=' + offset + '-' + end
          },
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          readTimeout: 120000,
          connectTimeout: 30000
        });
        if (resp.responseCode !== 206 && resp.responseCode !== 200) {
          await this.discardPart(partPath);
          return Result.fail(resp.responseCode, '下载失败');
        }
        const data = new Uint8Array(resp.result as ArrayBuffer);
        let writeRes: Result<boolean>;
        if (offset === 0) {
          writeRes = await this.localFileService.writeFile(partPath, data);
        } else {
          writeRes = await this.localFileService.appendFile(partPath, data);
        }
        if (!writeRes.success) {
          await this.discardPart(partPath);
          return Result.fail(-1, '写入本地文件失败：' + writeRes.errorMessage);
        }
        offset += data.length;
        onProgress(offset, total);
      }
      const finalRes = await this.localFileService.atomicReplace(partPath, localPath);
      if (!finalRes.success) {
        await this.discardPart(partPath);
        return Result.fail(-1, '文件落盘失败');
      }
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'WebDAVSync', 'download EXCEPTION path=%{public}s code=%{public}d msg=%{public}s',
        localPath, err.code, err.message);
      await this.discardPart(partPath);
      return Result.fail(-1, '下载异常：' + err.message);
    }
  }

  async uploadFile(conn: Connection, localPath: string, relativePath: string, onProgress: ProgressCallback): Promise<Result<boolean>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const statRes = await this.localFileService.stat(localPath);
      if (!statRes.success || statRes.data === null) {
        return Result.fail(-1, '本地文件不存在');
      }
      const total = statRes.data.size;
      if (total === 0) {
        // The http module rejects both an empty string and a zero-length ArrayBuffer as a
        // request body (401 Parameter error), so an empty file goes up as a PUT with no body.
        const emptyResp = await this.httpClient.request(url, {
          method: http.RequestMethod.PUT,
          header: {
            'Authorization': auth,
            'Content-Type': 'application/octet-stream',
            'X-OC-Mtime': Math.floor(statRes.data.mtime).toString()
          },
          readTimeout: 120000,
          connectTimeout: 30000
        });
        if (emptyResp.responseCode >= 200 && emptyResp.responseCode < 300) {
          onProgress(0, 0);
          return Result.ok(true);
        }
        return Result.fail(emptyResp.responseCode, '上传失败 HTTP ' + emptyResp.responseCode.toString());
      }
      const full = await this.localFileService.readFileRange(localPath, 0, total);
      if (!full.success || full.data === null) {
        return Result.fail(-1, '读取本地文件失败');
      }
      const resp = await this.httpClient.request(url, {
        method: http.RequestMethod.PUT,
        header: {
          'Authorization': auth,
          'Content-Type': 'application/octet-stream',
          'X-OC-Mtime': Math.floor(statRes.data.mtime).toString()
        },
        extraData: full.data.buffer as ArrayBuffer,
        readTimeout: 120000,
        connectTimeout: 30000
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        onProgress(total, total);
        return Result.ok(true);
      }
      return Result.fail(resp.responseCode, '上传失败 HTTP ' + resp.responseCode.toString());
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'WebDAVSync', 'upload EXCEPTION path=%{public}s code=%{public}d msg=%{public}s',
        relativePath, err.code, err.message);
      return Result.fail(-1, '上传异常：' + err.message);
    }
  }

  async deleteItem(conn: Connection, relativePath: string): Promise<Result<boolean>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: http.RequestMethod.DELETE,
        header: { 'Authorization': auth },
        readTimeout: 30000,
        connectTimeout: 30000
      });
      return Result.ok(resp.responseCode >= 200 && resp.responseCode < 300);
    } catch (e) {
      return Result.fail(-1, '删除失败');
    }
  }

  async mkdir(conn: Connection, relativePath: string): Promise<Result<boolean>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'MKCOL' as http.RequestMethod,
        header: { 'Authorization': auth },
        readTimeout: 30000,
        connectTimeout: 30000
      });
      return Result.ok(resp.responseCode >= 200 && resp.responseCode < 300);
    } catch (e) {
      return Result.fail(-1, '创建目录失败');
    }
  }
}