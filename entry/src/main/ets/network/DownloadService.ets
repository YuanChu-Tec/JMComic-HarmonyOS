import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { UIContext } from '@kit.ArkUI';
import { ApiService } from './ApiService';
import { HttpClient } from './HttpClient';
import {
  DownloadTask,
  DownloadStatus,
  JmImageInfo,
  IDownloadTaskJSON,
  PictureData,
} from '../models/Album';
import { APP_HEADERS_IMAGE } from '../common/Constants';
import { CacheManager } from '../common/CacheManager';
import { DecodedImageCache } from '../common/DecodedImageCache';
import { ImageDecodeUtils } from '../common/ImageDecodeUtils';
import { DownloadNotifier, DownloadAggregateStats } from '../common/DownloadNotifier';

/** 加入下载队列的章节描述（详情页构建） */
export interface ChapterDownloadInfo {
  photoId: string;
  photoName: string;
  scrambleId: number;
}

/**
 * 下载服务（全局单例）
 *
 * 章节级任务队列：后台逐章下载，支持暂停/继续/删除，任务经 CacheManager 持久化
 * （应用重启后非终态任务恢复为已暂停，可手动继续，已下载文件按序号断点续传）。
 *
 * 图片管线：优先复用阅读器已解码缓存 → 网络拉取原图 → scramble 解码还原 →
 * 重编码 PNG 落盘 → 回写解码缓存。
 *
 * 落盘结构：filesDir/JMComic/download/{专辑名}_{专辑ID}/{章节名}/{序号}.png
 * （目录名已做非法字符清洗；同专辑章节重名时追加章节 ID 防互写）
 *
 * 专辑全部章节完成时经 DownloadNotifier 发布通知并 toast 提醒；
 * 导出 zip 由下载管理页手动触发（见 common/ZipExporter）。
 */
export class DownloadService {
  private static instance: DownloadService | null = null;
  private static initPromise: Promise<DownloadService> | null = null;

  private tasks: Map<string, DownloadTask> = new Map();
  private running: boolean = false;
  /** 回调：任务状态变化时通知 UI（下载管理页） */
  onTaskUpdated: (() => void) | null = null;
  private cache: CacheManager | null = null;
  private baseDir: string = '';
  private decodedCache: DecodedImageCache | null = null;
  // ── 后台长时任务（DATA_TRANSFER + 实况通知）状态 ──
  /** 连续任务 ID（startBackgroundRunning 返回；<0 表示未申请） */
  private bgTaskId: number = -1;
  private bgStarting: boolean = false;
  /** 用户划掉实况通知触发 continuousTaskCancel 后置位：同步暂停全部任务，恢复下载时复位 */
  private bgUserCancelled: boolean = false;
  private cancelListenerRegistered: boolean = false;

  private constructor() {
  }

  /** 获取全局单例（首次调用时初始化下载目录与任务缓存恢复） */
  static getInstance(): Promise<DownloadService> {
    if (DownloadService.instance !== null) {
      return Promise.resolve(DownloadService.instance);
    }
    if (DownloadService.initPromise === null) {
      DownloadService.initPromise = (async (): Promise<DownloadService> => {
        let svc = new DownloadService();
        await svc.init();
        DownloadService.instance = svc;
        return svc;
      })();
    }
    return DownloadService.initPromise;
  }

  private async init(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    this.baseDir = `${context.filesDir}/JMComic/download`;
    this.decodedCache = await DecodedImageCache.getInstance();
    await this.initCache();
  }

  /** 从缓存恢复任务；非终态任务恢复为已暂停（等待手动继续） */
  private async initCache(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    let raw = this.cache.loadDownloadTasks();
    try {
      let items = JSON.parse(raw) as IDownloadTaskJSON[];
      for (let item of items) {
        let task = DownloadTask.fromJSON(item);
        if (task.status === DownloadStatus.DOWNLOADING || task.status === DownloadStatus.QUEUED) {
          task.status = DownloadStatus.PAUSED;
        }
        this.tasks.set(task.taskId, task);
      }
    } catch {
      // 缓存内容异常时忽略，视为空任务列表
    }
  }

  /** 同步任务到缓存 */
  syncToCache(): void {
    if (!this.cache) return;
    let items: IDownloadTaskJSON[] = [];
    this.tasks.forEach((task) => items.push(task.toJSON()));
    this.cache.saveDownloadTasks(JSON.stringify(items));
  }

  /** 获取所有任务（副本，供 UI 使用） */
  getTasks(): DownloadTask[] {
    let list: DownloadTask[] = [];
    this.tasks.forEach((task) => list.push(task));
    return list;
  }

  /**
   * 将整本漫画的全部章节批量加入下载队列（已存在的章节任务自动跳过）
   * @returns 新增的任务数
   */
  addAlbumTasks(albumId: number, albumName: string, chapters: ChapterDownloadInfo[]): number {
    let added = 0;
    // 本地下载目录已不存在（如导出后自动清理过）时，已完成任务重置为待下载，支持重新下载
    let filesMissing = !fileIo.accessSync(this.getAlbumDir(albumId, albumName));
    for (let ch of chapters) {
      let taskId = `${albumId}_${ch.photoId}`;
      let existing = this.tasks.get(taskId);
      if (existing) {
        if (filesMissing && (existing.status as string) === (DownloadStatus.DONE as string)) {
          existing.status = DownloadStatus.QUEUED;
          existing.completedImages = 0;
          existing.errorMsg = '';
          added++;
        }
        continue;
      }
      let task = new DownloadTask();
      task.taskId = taskId;
      task.albumId = albumId;
      task.albumName = albumName;
      task.photoId = ch.photoId;
      task.chapterName = ch.photoName;
      task.scrambleId = ch.scrambleId;
      task.status = DownloadStatus.QUEUED;
      task.addTime = Date.now();
      this.tasks.set(taskId, task);
      added++;
    }
    if (added > 0) {
      // 专辑加入了新章节，此前"已导出"的压缩包不再完整，重置导出状态
      this.cache?.setAlbumExported(albumId, false);
      this.notifyUpdate();
      this.processQueue();
    }
    return added;
  }

  /** 删除整本漫画的下载任务与本地已下载文件（下载管理页专辑删除/管理态批量删除用） */
  deleteAlbumTasks(albumId: number, albumName: string): void {
    let ids: string[] = [];
    let photoIds: string[] = [];
    this.tasks.forEach((task: DownloadTask) => {
      if (task.albumId === albumId) {
        // 正在下载的先置暂停，让执行循环在当前图片后停下
        if (task.status === DownloadStatus.DOWNLOADING) {
          task.status = DownloadStatus.PAUSED;
        }
        ids.push(task.taskId);
        photoIds.push(task.photoId);
      }
    });
    for (let id of ids) {
      this.tasks.delete(id);
    }
    if (ids.length > 0) {
      this.notifyUpdate();
      this.processQueue();
    }
    // 连带删除本地已下载文件（rmdirSync 支持递归删除非空目录）
    let dir = this.getAlbumDir(albumId, albumName);
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      console.warn(`[DownloadService] remove album dir failed: ${JSON.stringify(e)}`);
    }
    // 连带清理解码缓存副本（cacheDir/decoded/{photoId}）
    for (let pid of photoIds) {
      this.decodedCache?.deleteChapterCache(pid);
    }
  }

  /** 仅删除整本漫画的本地已下载文件，保留任务记录（「导出成功后自动删除下载缓存」设置开启时由导出流程调用） */
  deleteAlbumFiles(albumId: number, albumName: string): void {
    let dir = this.getAlbumDir(albumId, albumName);
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      console.warn(`[DownloadService] remove album files failed: ${JSON.stringify(e)}`);
    }
    // 连带清理解码缓存副本（cacheDir/decoded/{photoId}）：下载时会回写第二份到缓存，
    // 不清理的话「减少空间占用」只兑现了一半，且设置页缓存体积不会下降
    this.tasks.forEach((task: DownloadTask) => {
      if (task.albumId === albumId) {
        this.decodedCache?.deleteChapterCache(task.photoId);
      }
    });
  }

  /** 暂停任务（当前正在下载的图片完成后停下，进度已持久化） */
  pauseTask(taskId: string): void {
    let task = this.tasks.get(taskId);
    if (task && task.status === DownloadStatus.DOWNLOADING) {
      task.status = DownloadStatus.PAUSED;
      this.notifyUpdate();
    }
  }

  /** 继续任务（已暂停/失败的任务重新排队，已下载文件按序号断点续传） */
  resumeTask(taskId: string): void {
    let task = this.tasks.get(taskId);
    if (task && (task.status === DownloadStatus.PAUSED || task.status === DownloadStatus.ERROR)) {
      task.status = DownloadStatus.QUEUED;
      task.errorMsg = '';
      this.notifyUpdate();
      this.processQueue();
    }
  }

  /** 删除任务记录（已下载的图片文件保留，供后续导出） */
  removeTask(taskId: string): void {
    let task = this.tasks.get(taskId);
    if (task && task.status === DownloadStatus.DOWNLOADING) {
      task.status = DownloadStatus.PAUSED;
    }
    this.tasks.delete(taskId);
    this.notifyUpdate();
    this.processQueue();
  }

  /** 处理下载队列（串行逐章执行） */
  private async processQueue(): Promise<void> {
    if (this.running) return;
    this.running = true;

    // 下载开始即申请长时任务：官方推荐「退后台前申请」（onBackground），但申请涉及通知授权弹窗
    // 等异步流程，退后台瞬间才申请有竞态，下载开始即申请最稳；失败降级为仅前台下载
    await this.ensureBackgroundRunning();

    try {
      while (this.hasPendingTasks()) {
        let task = this.getNextQueuedTask();
        if (!task) break;

        task.status = DownloadStatus.DOWNLOADING;
        this.notifyUpdate();

        try {
          await this.executeDownload(task);
          if ((task.status as string) === (DownloadStatus.DOWNLOADING as string)) {
            task.status = DownloadStatus.DONE;
            this.notifyUpdate();
            if (this.isAlbumAllDone(task.albumId)) {
              let count = this.albumTaskCount(task.albumId);
              DownloadNotifier.notifyAlbumDone(task.albumId, task.albumName, count);
              this.toastAlbumDone(task.albumName);
            }
          }
        } catch (err) {
          if ((task.status as string) !== (DownloadStatus.PAUSED as string)) {
            task.status = DownloadStatus.ERROR;
            task.errorMsg = (err as Error).message || '未知错误';
            this.notifyUpdate();
            DownloadNotifier.notifyTaskError(task.albumId, task.albumName, task.chapterName, task.errorMsg);
          }
        }
        // 注意：单个章节被暂停/删除后不再 break——继续处理其余排队章节。
        // 旧实现在此 break，暂停/删除正在下载的章节会让整个队列停摆，
        // 表现为「通知写着下载中，实际没有在下」（2026-11-26 修复）
      }
    } finally {
      this.running = false;
      // 队列排空立即释放长时任务，实况通知随之撤销
      if (!this.hasPendingTasks()) {
        this.stopBackgroundTask();
      }
    }
  }

  // ═══════════════════════════════════════════════════════
  // 后台长时任务（DATA_TRANSFER）+ 实况进度通知
  // 硬约束（SDK 声明实证，2026-11-26）：三方不能自建实况通知，只能申请长时任务由系统代建，
  // 之后用返回的同一通知 ID 发布更新刷新进度；用户划掉实况通知会连带取消长时任务。
  // ═══════════════════════════════════════════════════════

  /** 申请长时任务（幂等）：申请成功后系统代建实况通知，进度经 DownloadNotifier 同 ID 更新 */
  private async ensureBackgroundRunning(): Promise<void> {
    if (this.bgTaskId >= 0 || this.bgStarting) return;
    this.bgUserCancelled = false;
    this.bgStarting = true;
    try {
      let context = getContext() as common.UIAbilityContext;
      // 通知授权：首次下载弹系统授权框；拒绝后发布静默失败，不影响下载本身
      try {
        let enabled = await notificationManager.isNotificationEnabled();
        if (!enabled) {
          await notificationManager.requestEnableNotification(context);
        }
      } catch (e) {
        console.warn('[DownloadService] request notification enable failed: ' + JSON.stringify(e));
      }

      let info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      };
      let agent = await wantAgent.getWantAgent(info);
      // 返回对象带 slotType/contentType/notificationId/continuousTaskId，是实况进度更新的键
      let taskNotification: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
      this.bgTaskId = taskNotification.continuousTaskId ?? -1;
      DownloadNotifier.liveNotificationId = taskNotification.notificationId;
      this.registerCancelListener();
      console.info(`[DownloadService] background running started, notificationId=${taskNotification.notificationId}`);
    } catch (e) {
      console.warn('[DownloadService] start background running failed: ' + JSON.stringify(e));
    } finally {
      this.bgStarting = false;
    }
  }

  /** 监听长时任务被取消（用户划掉实况通知）：同步暂停全部任务，避免「通知已撤、下载照跑」 */
  private registerCancelListener(): void {
    if (this.cancelListenerRegistered) return;
    this.cancelListenerRegistered = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        if (DownloadNotifier.liveNotificationId < 0) {
          return; // 本应用当前没有在册的长时任务，忽略（防御其他场景的事件）
        }
        console.info('[DownloadService] continuous task canceled by user: ' + JSON.stringify(info));
        this.bgTaskId = -1;
        DownloadNotifier.liveNotificationId = -1;
        this.bgUserCancelled = true;
        this.pauseAllForTaskCancel();
      });
    } catch (e) {
      this.cancelListenerRegistered = false;
      console.warn('[DownloadService] register cancel listener failed: ' + JSON.stringify(e));
    }
  }

  /** 用户取消后台任务后的状态同步：全部非终态任务置暂停，可从下载管理页手动继续 */
  private pauseAllForTaskCancel(): void {
    let changed = false;
    this.tasks.forEach((task: DownloadTask) => {
      if (task.status === DownloadStatus.DOWNLOADING || task.status === DownloadStatus.QUEUED) {
        task.status = DownloadStatus.PAUSED;
        changed = true;
      }
    });
    if (changed) {
      this.notifyUpdate();
    }
  }

  /** 释放长时任务（队列排空时调用）；实况通知随任务撤销 */
  private stopBackgroundTask(): void {
    if (this.bgTaskId < 0 && DownloadNotifier.liveNotificationId < 0) return;
    let taskId = this.bgTaskId;
    this.bgTaskId = -1;
    DownloadNotifier.liveNotificationId = -1;
    let context = getContext() as common.UIAbilityContext;
    try {
      if (taskId >= 0) {
        // 与 string[] 形式 startBackgroundRunning 配对的是带 continuousTaskId 的 stop（API 15+）
        backgroundTaskManager.stopBackgroundRunning(context, taskId).catch((e: Error) => {
          console.warn('[DownloadService] stop background running failed: ' + JSON.stringify(e));
        });
      } else {
        backgroundTaskManager.stopBackgroundRunning(context).catch((e: Error) => {
          console.warn('[DownloadService] stop background running failed: ' + JSON.stringify(e));
        });
      }
    } catch (e) {
      console.warn('[DownloadService] stop background running error: ' + JSON.stringify(e));
    }
  }

  /** 构建全局汇总进度快照（以当前正在下载的章节为「当前章节」） */
  private buildProgressStats(current: DownloadTask): DownloadAggregateStats {
    let stats: DownloadAggregateStats = {
      totalChapters: 0,
      doneChapters: 0,
      totalImages: 0,
      doneImages: 0,
      currentChapter: current.chapterName
    };
    this.tasks.forEach((task: DownloadTask) => {
      stats.totalChapters++;
      if (task.status === DownloadStatus.DONE) {
        stats.doneChapters++;
      }
      stats.totalImages += task.totalImages;
      stats.doneImages += task.completedImages;
    });
    return stats;
  }

  /** 实际执行下载一个章节的所有图片（失败时抛出，由队列标记 ERROR） */
  private async executeDownload(task: DownloadTask): Promise<void> {
    let apiService = ApiService.getInstance();

    // 1. 获取图片列表（含真实 scramble_id）
    let pictureData: PictureData = await apiService.getChapterPictures(task.photoId, task.scrambleId);
    let images: JmImageInfo[] = pictureData.pictures.images;
    let scrambleId: number = pictureData.pictures.scramble_id || task.scrambleId;
    task.totalImages = images.length;
    // 章节内容与本地进度不符（服务端改版）时重置进度
    if (task.completedImages > images.length) {
      task.completedImages = 0;
    }
    this.notifyUpdate();

    // 2. 准备目录
    let dirPath = this.getChapterDir(task);
    this.ensureDir(dirPath);

    // 3. 逐张下载（scramble 解码后 PNG 落盘，序号即阅读顺序）
    for (let i = 0; i < images.length; i++) {
      if ((task.status as string) === (DownloadStatus.PAUSED as string)) {
        break;
      }

      let img: JmImageInfo = images[i];
      task.currentImageName = img.img_name;
      this.notifyUpdate();

      let destPath = `${dirPath}/${i + 1}.png`;
      try {
        if (fileIo.accessSync(destPath)) {
          // 断点续传：目标文件已存在，直接计入完成
          if (task.completedImages < i + 1) {
            task.completedImages = i + 1;
            this.notifyUpdate();
          }
          continue;
        }

        await this.downloadImage(task.photoId, i, scrambleId, img, destPath);
        task.completedImages = i + 1;
        this.notifyUpdate();
        // 实况/普通进度通知：内容为全局汇总（x/y 章 · n/m 页 · 百分比），节流在通知器内部
        DownloadNotifier.notifyAggregateProgress(task.albumId, task.albumName,
          this.buildProgressStats(task));
      } catch (err) {
        console.error(`[DownloadService] image failed: ${img.img_name}, ${(err as Error).message}`);
        // 单张失败不中断整体，继续下一张
      }
    }

    // 缺页校验：仍有未落盘的图片时标记失败（用户点「继续」可断点补齐），避免静默产出空包/缺页包
    if ((task.status as string) === (DownloadStatus.DOWNLOADING as string)
      && task.totalImages > 0 && task.completedImages < task.totalImages) {
      throw new Error(`有 ${task.totalImages - task.completedImages} 张图片下载失败`);
    }
  }

  /**
   * 下载单张图片：优先复制已解码缓存 → 网络拉取 → scramble 解码 → PNG 落盘 → 回写缓存
   */
  private async downloadImage(
    photoId: string, index: number,
    scrambleId: number, img: JmImageInfo,
    destPath: string
  ): Promise<void> {
    // 1. 优先从阅读器已解码缓存复制（免网络请求；浏览过/预加载过的页面瞬间完成即来源于此）
    if (this.decodedCache && this.decodedCache.hasCached(photoId, index)) {
      let cachePath = this.decodedCache.getCacheFilePath(photoId, index);
      try {
        fileIo.copyFileSync(cachePath, destPath);
        console.info(`[DownloadService] copied from decoded cache: ${photoId}/${index}`);
        return;
      } catch (e) {
        console.warn(`[DownloadService] copy from decoded cache failed: ${photoId}/${index}`);
      }
    }

    // 2. 网络下载原始图（失败等待后重试一次）
    let url = img.img_url || img.download_url;
    if (!url || url.length === 0) {
      throw new Error(`图片地址为空: ${img.img_name}`);
    }
    let data: ArrayBuffer;
    try {
      data = await HttpClient.downloadBinary(url, APP_HEADERS_IMAGE);
    } catch (err) {
      await HttpClient.sleep(1500);
      data = await HttpClient.downloadBinary(url, APP_HEADERS_IMAGE);
    }

    // 3. 解码为 PixelMap 并做 scramble 还原
    let imageSource = image.createImageSource(data);
    let pixelMap = await imageSource.createPixelMap({
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
    });
    imageSource.release();

    let imgNameNoExt = img.img_name.replace(/\.[^.]+$/, '');
    let num = await ImageDecodeUtils.getSegmentationNum(
      scrambleId,
      parseInt(photoId),
      imgNameNoExt
    );
    if (num > 0) {
      pixelMap = await ImageDecodeUtils.decodeImage(pixelMap, num);
    }

    // 4. PNG 落盘并回写解码缓存（后续阅读/重复下载免网络）
    await this.savePixelMapToFile(pixelMap, destPath);
    if (this.decodedCache) {
      // 异步回写，编码完成后才释放 PixelMap——不等待就 release 会在编码中途撤走编码源，
      // 高概率导致缓存回写失败（saveDecodedImage 内部已自捕获异常，这里仅兜底 + 释放）
      this.decodedCache.saveDecodedImage(photoId, index, pixelMap)
        .catch((_e: Error) => {
        })
        .finally(() => pixelMap.release());
      return;
    }
    pixelMap.release();
  }

  /** 将 PixelMap 编码为 PNG 写入文件 */
  private async savePixelMapToFile(pixelMap: image.PixelMap, filePath: string): Promise<void> {
    let packer = image.createImagePacker();
    let packOpts: image.PackingOption = {
      format: 'image/png',
      quality: 100
    };
    let data = await packer.packing(pixelMap, packOpts);
    packer.release();
    let file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, data);
    fileIo.closeSync(file);
  }

  /** 专辑下载根目录：{baseDir}/{专辑名}_{专辑ID}（ZipExporter 同步使用，勿改格式） */
  getAlbumDir(albumId: number, albumName: string): string {
    return `${this.baseDir}/${DownloadService.sanitizeFileName(albumName)}_${albumId}`;
  }

  /** 章节目录：同专辑内章节重名时追加 photoId，避免目录互写覆盖 */
  private getChapterDir(task: DownloadTask): string {
    let safeName = DownloadService.sanitizeFileName(task.chapterName || `第${task.photoId}话`);
    let duplicate = false;
    this.tasks.forEach((other: DownloadTask) => {
      if (other.albumId === task.albumId && other.photoId !== task.photoId
        && other.chapterName === task.chapterName) {
        duplicate = true;
      }
    });
    if (duplicate) {
      safeName = `${safeName}_${task.photoId}`;
    }
    return `${this.getAlbumDir(task.albumId, task.albumName)}/${safeName}`;
  }

  /** 专辑章节任务是否已全部完成（至少有一个任务才算） */
  private isAlbumAllDone(albumId: number): boolean {
    let total = 0;
    let allDone = true;
    this.tasks.forEach((task: DownloadTask) => {
      if (task.albumId === albumId) {
        total++;
        if (task.status !== DownloadStatus.DONE) {
          allDone = false;
        }
      }
    });
    return total > 0 && allDone;
  }

  private albumTaskCount(albumId: number): number {
    let total = 0;
    this.tasks.forEach((task: DownloadTask) => {
      if (task.albumId === albumId) total++;
    });
    return total;
  }

  /** 专辑下载完成的应用内 toast（经全局 UIContext，服务层无页面上下文） */
  private toastAlbumDone(albumName: string): void {
    let uiContext = AppStorage.get<UIContext>('globalUIContext') ?? null;
    if (!uiContext) return;
    try {
      uiContext.getPromptAction().showToast({
        message: `《${albumName}》下载完成，可到「下载管理」导出压缩包`,
        duration: 3000
      });
    } catch (e) {
      console.warn('[DownloadService] toast error: ' + JSON.stringify(e));
    }
  }

  private notifyUpdate(): void {
    this.syncToCache();
    if (this.onTaskUpdated) {
      this.onTaskUpdated();
    }
  }

  private hasPendingTasks(): boolean {
    for (let task of this.tasks.values()) {
      if (task.status === DownloadStatus.QUEUED) return true;
    }
    return false;
  }

  private getNextQueuedTask(): DownloadTask | null {
    for (let task of this.tasks.values()) {
      if (task.status === DownloadStatus.QUEUED) return task;
    }
    return null;
  }

  private ensureDir(dirPath: string): void {
    if (!fileIo.accessSync(dirPath)) {
      fileIo.mkdirSync(dirPath, true);
    }
  }

  /** 清理文件名中的非法字符（目录/文件名统一入口） */
  static sanitizeFileName(name: string): string {
    return name.replace(/[\/\\:*?"<>|]/g, '_').trim();
  }
}
