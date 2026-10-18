import { describe, it, expect } from '@ohos/hypium';
import { Result } from '../main/ets/domain/Result';
import { ChangeSet } from '../main/ets/domain/ChangeSet';
import { FileChange } from '../main/ets/domain/ChangeSet';
import { ChangeType } from '../main/ets/domain/Enums';
import { ChangeDetector } from '../main/ets/domain/ChangeDetector';
import { FileEntry } from '../main/ets/domain/FileEntry';
import { FileState } from '../main/ets/domain/FileState';

export default function localTest() {
  describe('ResultTest', () => {
    it('result_ok', 0, () => {
      const r = Result.ok(42);
      expect(r.success).assertTrue();
      expect(r.data).assertEqual(42);
    });

    it('result_fail', 0, () => {
      const r = Result.fail(1001, 'error');
      expect(r.success).assertFalse();
      expect(r.errorCode).assertEqual(1001);
      expect(r.errorMessage).assertEqual('error');
    });
  });

  describe('ChangeSetTest', () => {
    it('changeset_total_and_filter', 0, () => {
      const cs = new ChangeSet();
      const a = new FileChange();
      a.relPath = 'a.txt';
      a.changeType = ChangeType.Add;
      const b = new FileChange();
      b.relPath = 'b.txt';
      b.changeType = ChangeType.Modify;
      cs.add(a);
      cs.add(b);
      expect(cs.total).assertEqual(2);
      expect(cs.filterByType(ChangeType.Add).length).assertEqual(1);
      expect(cs.filterByType(ChangeType.Delete).length).assertEqual(0);
    });
  });

  describe('ChangeDetectorLocalTest', () => {
    it('local_add_when_no_prev', 0, () => {
      const e = new FileEntry('a.txt', false, 10, 100, '');
      expect(ChangeDetector.isLocalChanged(e, undefined)).assertTrue();
    });

    it('local_unchanged_when_mtime_equal', 0, () => {
      const e = new FileEntry('a.txt', false, 10, 100, '');
      const p = new FileState();
      p.localMtime = 100;
      expect(ChangeDetector.isLocalChanged(e, p)).assertFalse();
    });

    it('local_modified_when_mtime_diff', 0, () => {
      const e = new FileEntry('a.txt', false, 10, 200, '');
      const p = new FileState();
      p.localMtime = 100;
      expect(ChangeDetector.isLocalChanged(e, p)).assertTrue();
    });

    it('local_delete_when_entry_gone', 0, () => {
      const p = new FileState();
      p.localMtime = 100;
      expect(ChangeDetector.isLocalChanged(undefined, p)).assertTrue();
    });
  });

  describe('ChangeDetectorRemoteTest', () => {
    it('remote_add_when_no_prev', 0, () => {
      const e = new FileEntry('a.txt', false, 10, 0, 'etag1');
      expect(ChangeDetector.isRemoteChanged(e, undefined)).assertTrue();
    });

    it('remote_changed_when_etag_diff', 0, () => {
      const e = new FileEntry('a.txt', false, 10, 0, 'etag2');
      const p = new FileState();
      p.remoteEtag = 'etag1';
      expect(ChangeDetector.isRemoteChanged(e, p)).assertTrue();
    });

    it('remote_unchanged_when_etag_same', 0, () => {
      const e = new FileEntry('a.txt', false, 10, 0, 'etag1');
      const p = new FileState();
      p.remoteEtag = 'etag1';
      expect(ChangeDetector.isRemoteChanged(e, p)).assertFalse();
    });

    it('remote_delete_when_entry_gone', 0, () => {
      const p = new FileState();
      p.remoteEtag = 'etag1';
      expect(ChangeDetector.isRemoteChanged(undefined, p)).assertTrue();
    });
  });
}