import { common, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';

/**
 * 下载系统通知（静默形态：仅通知栏展示，不弹窗打断，点击回到应用）
 * 自 AlbumDetailPage 旧实现迁移；进度通知按最低间隔节流，避免逐图刷新
 */
export class DownloadNotifier {
  private static wantAgentObj: object | null = null;
  private static lastProgressTick: number = 0;
  private static readonly THROTTLE_MS = 1000;

  private static async ensureWantAgent(): Promise<object | null> {
    if (DownloadNotifier.wantAgentObj) {
      return DownloadNotifier.wantAgentObj;
    }
    try {
      let context = getContext() as common.UIAbilityContext;
      let info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      };
      DownloadNotifier.wantAgentObj = await wantAgent.getWantAgent(info);
    } catch (e) {
      console.warn('[DownloadNotifier] wantAgent error: ' + JSON.stringify(e));
    }
    return DownloadNotifier.wantAgentObj;
  }

  /** 通知 id：按专辑隔离，同一专辑的进度/完成通知互相覆盖 */
  private static id(albumId: number): number {
    return 200000 + albumId;
  }

  /** 发布通知；系统未授权等场景静默失败，不影响下载本身 */
  private static async publish(request: notificationManager.NotificationRequest): Promise<void> {
    try {
      let agent = await DownloadNotifier.ensureWantAgent();
      if (agent) {
        request.wantAgent = agent as Record<string, Object>;
      }
      await notificationManager.publish(request);
    } catch (e) {
      console.warn('[DownloadNotifier] publish error: ' + JSON.stringify(e));
    }
  }

  /** 章节下载进度通知（模板进度条），按最低间隔节流 */
  static notifyProgress(albumId: number, albumName: string, chapterName: string,
    current: number, total: number): void {
    let now = Date.now();
    if (now - DownloadNotifier.lastProgressTick < DownloadNotifier.THROTTLE_MS) {
      return;
    }
    DownloadNotifier.lastProgressTick = now;
    let percent = total > 0 ? Math.round(current / total * 100) : 0;
    try {
      let template: notificationManager.NotificationTemplate = {
        name: 'downloadTemplate',
        data: {
          progressValue: current,
          progressMaxValue: total,
          isProgressIndeterminate: false
        }
      };
      let req: notificationManager.NotificationRequest = {
        id: DownloadNotifier.id(albumId),
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        template: template,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: `正在下载：${albumName}`,
            text: chapterName,
            additionalText: `${percent}% (${current}/${total})`
          }
        }
      };
      DownloadNotifier.publish(req);
    } catch (e) {
      console.warn('[DownloadNotifier] build progress req error: ' + JSON.stringify(e));
    }
  }

  /** 专辑全部章节下载完成通知 */
  static notifyAlbumDone(albumId: number, albumName: string, totalChapters: number): void {
    try {
      let req: notificationManager.NotificationRequest = {
        id: DownloadNotifier.id(albumId),
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: `下载完成：${albumName}`,
            text: `共 ${totalChapters} 个章节，可到「下载管理」导出压缩包`,
            additionalText: '完成'
          }
        }
      };
      DownloadNotifier.publish(req);
    } catch (e) {
      console.warn('[DownloadNotifier] build done req error: ' + JSON.stringify(e));
    }
  }

  /** 单章节下载失败通知 */
  static notifyTaskError(albumId: number, albumName: string, chapterName: string, msg: string): void {
    try {
      let req: notificationManager.NotificationRequest = {
        id: DownloadNotifier.id(albumId),
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: `下载失败：${albumName}`,
            text: `${chapterName}：${msg}`,
            additionalText: '失败'
          }
        }
      };
      DownloadNotifier.publish(req);
    } catch (e) {
      console.warn('[DownloadNotifier] build error req error: ' + JSON.stringify(e));
    }
  }
}
