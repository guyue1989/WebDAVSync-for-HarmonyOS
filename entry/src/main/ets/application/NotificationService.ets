import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import { SyncResult } from '../domain/SyncResult';
import { SyncStatus } from '../domain/Enums';

export interface INotificationService {
  notify(title: string, text: string): Promise<void>;
  notifySyncResult(result: SyncResult): Promise<void>;
}

export class NotificationService implements INotificationService {
  private seqId: number = 1000;

  async notify(title: string, text: string): Promise<void> {
    const request: notificationManager.NotificationRequest = {
      id: this.seqId++,
      content: {
        notificationContentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    };
    await notificationManager.publish(request);
  }

  async notifySyncResult(result: SyncResult): Promise<void> {
    // A poll that lands inside a running pass is not a failure, it just means the previous
    // pass is still working.
    if (result.busy) {
      return;
    }
    if (result.status === SyncStatus.Completed) {
      if (result.message === '无变化') {
        return;
      }
      await this.notify('WebDAV 同步完成', result.message);
    } else if (result.status === SyncStatus.Error) {
      await this.notify('WebDAV 同步失败', result.message);
    } else if (result.conflicts.length > 0) {
      await this.notify('WebDAV 同步冲突', '检测到 ' + result.conflicts.length.toString() + ' 个冲突');
    }
  }
}