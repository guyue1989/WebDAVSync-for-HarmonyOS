import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import wantAgent from '@ohos.app.ability.wantAgent';
import { AppContext } from './AppContext';
import { Result } from '../domain/Result';

const TRAY_NOTIFICATION_ID = 9999;
const BUNDLE_NAME = 'com.niangao.webdavsync';

export interface ITrayService {
  show(): Promise<Result<boolean>>;
  hide(): Promise<Result<boolean>>;
}

export class TrayService implements ITrayService {
  private visible: boolean = false;

  async show(): Promise<Result<boolean>> {
    if (this.visible) {
      return Result.ok(true);
    }
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return Result.fail(-1, 'context 为空');
    }
    try {
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: BUNDLE_NAME,
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(agentInfo);

      const request: notificationManager.NotificationRequest = {
        id: TRAY_NOTIFICATION_ID,
        content: {
          notificationContentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'WebDAV 同步',
            text: '应用正在后台运行，点击恢复',
            additionalText: ''
          }
        },
        wantAgent: agent,
        isOngoing: true
      };
      await notificationManager.publish(request);
      this.visible = true;
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '托盘通知发布失败');
    }
  }

  async hide(): Promise<Result<boolean>> {
    if (!this.visible) {
      return Result.ok(true);
    }
    try {
      await notificationManager.cancel(TRAY_NOTIFICATION_ID);
      this.visible = false;
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '托盘通知取消失败');
    }
  }
}
