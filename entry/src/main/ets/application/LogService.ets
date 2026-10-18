import hilog from '@ohos.hilog';

export class LogEntry {
  time: string = '';
  level: string = '';
  message: string = '';
}

export class LogService {
  private static instance: LogService | null = null;
  private entries: LogEntry[] = [];
  private static readonly MAX_ENTRIES = 200;

  static get(): LogService {
    if (LogService.instance === null) {
      LogService.instance = new LogService();
    }
    return LogService.instance;
  }

  info(message: string): void {
    this.add('INFO', message);
  }

  warn(message: string): void {
    this.add('WARN', message);
  }

  error(message: string): void {
    this.add('ERROR', message);
  }

  private add(level: string, message: string): void {
    hilog.info(0x0000, 'WebDAVSync', '%{public}s', message);
    const now = new Date();
    const hh = this.pad(now.getHours());
    const mm = this.pad(now.getMinutes());
    const ss = this.pad(now.getSeconds());
    const entry = new LogEntry();
    entry.time = hh + ':' + mm + ':' + ss;
    entry.level = level;
    entry.message = message;
    this.entries.push(entry);
    if (this.entries.length > LogService.MAX_ENTRIES) {
      this.entries.shift();
    }
  }

  private pad(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  getEntries(): LogEntry[] {
    return this.entries.slice();
  }

  clear(): void {
    this.entries = [];
  }
}