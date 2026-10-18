export class FileFilter {
  private patterns: string[] = [];

  constructor(rules: string = '') {
    this.parse(rules);
  }

  parse(rules: string): void {
    this.patterns = [];
    if (rules === '') {
      return;
    }
    const parts = rules.split(/[,，\n\t]/);
    for (const p of parts) {
      const t = p.trim();
      if (t !== '') {
        this.patterns.push(t);
      }
    }
  }

  matches(name: string): boolean {
    for (const p of this.patterns) {
      if (this.matchOne(p, name)) {
        return true;
      }
    }
    return false;
  }

  private matchOne(pattern: string, name: string): boolean {
    let re = '';
    for (let i = 0; i < pattern.length; i++) {
      const ch = pattern.charAt(i);
      if (ch === '*') {
        re += '.*';
      } else if ('\\^$.|?+()[]{}'.indexOf(ch) >= 0) {
        re += '\\' + ch;
      } else {
        re += ch;
      }
    }
    return new RegExp('^' + re + '$', 'i').test(name);
  }
}