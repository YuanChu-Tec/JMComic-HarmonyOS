import { common, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';

/** 全局下载汇总进度快照（DownloadService 构建传入），实况通知内容来源 */
export interface DownloadAggregateStats {
  /** 队列内章节总数（含排队/下载中/暂停/失败/已完成） */
  totalChapters: number;
  /** 已完成章节数 */
  doneChapters: number;
  /** 全部章节图片总数 */
  totalImages: number;
  /** 已落盘图片总数 */
  doneImages: number;
  /** 当前正在下载的章节名 */
  currentChapter: string;
}

/**
 * 下载系统通知（静默形态：仅通知栏展示，不弹窗打断，点击回到应用）
 *
 * 后台下载口径（2026-11-26）：DownloadService 申请长时任务（DATA_TRANSFER）成功后，
 * 系统代建实况（Live View）通知——三方不能自建实况，只能用返回的同一通知 ID 发布更新
 * 刷新进度；无长时任务时按专辑 ID 发普通进度通知兜底（旧行为）。
 * 进度更新按最低间隔节流，避免逐图刷新。
 */
export class DownloadNotifier {
  private static wantAgentObj: object | null = null;
  private static lastProgressTick: number = 0;
  private static readonly THROTTLE_MS = 1000;
  /** 长时任务实况通知 ID（申请成功后写入；<0 表示无实况任务，进度走普通通知兜底） */
  static liveNotificationId: number = -1;

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
        // actionType/actionFlags 为现行字段名（operationType/wantAgentFlags 已废弃）
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      };
      DownloadNotifier.wantAgentObj = await wantAgent.getWantAgent(info);
    } catch (e) {
      console.warn('[DownloadNotifier] wantAgent error: ' + JSON.stringify(e));
    }
    return DownloadNotifier.wantAgentObj;
  }

  /** 普通通知 id：按专辑隔离，同一专辑的进度/完成通知互相覆盖 */
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

  /** 全局汇总进度（实况/普通通知自动二选一），按最低间隔节流 */
  static notifyAggregateProgress(albumId: number, albumName: string, stats: DownloadAggregateStats): void {
    let now = Date.now();
    if (now - DownloadNotifier.lastProgressTick < DownloadNotifier.THROTTLE_MS) {
      return;
    }
    DownloadNotifier.lastProgressTick = now;
    let percent = stats.totalImages > 0 ? Math.round(stats.doneImages / stats.totalImages * 100) : 0;
    let useLive = DownloadNotifier.liveNotificationId >= 0;
    try {
      let template: notificationManager.NotificationTemplate = {
        name: 'downloadTemplate',
        data: {
          progressValue: stats.doneImages,
          progressMaxValue: Math.max(stats.totalImages, 1),
          isProgressIndeterminate: false
        }
      };
      let req: notificationManager.NotificationRequest = {
        id: useLive ? DownloadNotifier.liveNotificationId : DownloadNotifier.id(albumId),
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        template: template,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: `正在下载：${albumName}`,
            text: `已完成 ${stats.doneChapters}/${stats.totalChapters} 章 · ${percent}%`,
            additionalText: stats.currentChapter
          }
        }
      };
      DownloadNotifier.publish(req);
    } catch (e) {
      console.warn('[DownloadNotifier] build progress req error: ' + JSON.stringify(e));
    }
  }

  /** 专辑全部章节下载完成通知（独立于实况通知 ID，不被进度刷新覆盖） */
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
