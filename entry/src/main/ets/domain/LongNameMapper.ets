// HarmonyOS rejects path components longer than 255 bytes, while NAS-side names can
// exceed that (long Chinese regulation titles). Such a path is stored under a
// deterministic short local name; the original name stays the sync key.
// The limit has to match the filesystem exactly: shortening a name the local disk would
// have accepted would hide the real file from the snapshot and sync it under two names.
const COMPONENT_LIMIT = 255;
const LOCAL_TARGET_BYTES = 200;

export class LongNameMapper {
  static byteLength(s: string): number {
    let n = 0;
    let i = 0;
    while (i < s.length) {
      n += LongNameMapper.unitBytes(s, i);
      i += LongNameMapper.unitSize(s, i);
    }
    return n;
  }

  private static unitSize(s: string, i: number): number {
    const c = s.charCodeAt(i);
    return (c >= 0xD800 && c <= 0xDBFF) ? 2 : 1;
  }

  private static unitBytes(s: string, i: number): number {
    const c = s.charCodeAt(i);
    if (c < 0x80) {
      return 1;
    }
    if (c < 0x800) {
      return 2;
    }
    if (c >= 0xD800 && c <= 0xDBFF) {
      return 4;
    }
    return 3;
  }

  static needsShortening(relPath: string): boolean {
    const parts = relPath.split('/');
    for (const p of parts) {
      if (LongNameMapper.byteLength(p) > COMPONENT_LIMIT) {
        return true;
      }
    }
    return false;
  }

  static toLocalRel(relPath: string): string {
    const parts = relPath.split('/');
    const out: string[] = [];
    for (const p of parts) {
      out.push(LongNameMapper.toLocalName(p));
    }
    return out.join('/');
  }

  // Downloads are staged in `<target>.part` and then renamed, so the temporary name carries
  // five extra bytes: a maximum-length file would overflow it and never be written.
  // The suffix is folded in before shortening, which keeps the final name untouched.
  static withSuffix(path: string, suffix: string): string {
    const slash = path.lastIndexOf('/');
    const dir = slash < 0 ? '' : path.substring(0, slash + 1);
    const base = slash < 0 ? path : path.substring(slash + 1);
    return dir + LongNameMapper.toLocalName(base + suffix);
  }

  static toLocalName(name: string): string {
    if (LongNameMapper.byteLength(name) <= COMPONENT_LIMIT) {
      return name;
    }
    const dot = name.lastIndexOf('.');
    const hasExt = dot > 0;
    let ext = hasExt ? name.substring(dot) : '';
    // A suffix longer than that is not an extension, so keep it inside the hashed stem
    // instead of letting it push the short name past the limit again.
    if (LongNameMapper.byteLength(ext) > 32) {
      ext = '';
    }
    const stem = hasExt && ext !== '' ? name.substring(0, dot) : name;
    const suffix = '-' + LongNameMapper.hash(name) + ext;
    const head = LongNameMapper.truncate(stem, LOCAL_TARGET_BYTES - LongNameMapper.byteLength(suffix));
    return head + suffix;
  }

  private static truncate(s: string, maxBytes: number): string {
    let out = '';
    let used = 0;
    let i = 0;
    while (i < s.length) {
      const bytes = LongNameMapper.unitBytes(s, i);
      const size = LongNameMapper.unitSize(s, i);
      if (used + bytes > maxBytes) {
        break;
      }
      out += s.substring(i, i + size);
      used += bytes;
      i += size;
    }
    return out;
  }

  // djb2 kept inside 32 bits so every multiply stays exact in a double.
  private static hash(s: string): string {
    let h = 5381;
    for (let i = 0; i < s.length; i++) {
      h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    }
    return h.toString(16);
  }
}
