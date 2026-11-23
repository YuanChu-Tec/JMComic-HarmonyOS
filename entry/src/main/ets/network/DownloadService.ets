import { UIContext } from '@kit.ArkUI';
import { ApiService } from './ApiService';
import {
  DownloadTask,
  DownloadStatus,
  JmImageInfo,
  IDownloadTaskJSON,
  PictureData,
} from '../models/Album';
import { CacheManager } from '../common/CacheManager';
import { ComicLibrary, LibraryContext } from '../common/ComicLibrary';
import { DownloadNotifier } from '../common/DownloadNotifier';

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
 * 图片落盘由 ComicLibrary 统一管理：filesDir/JMComic/library/{专辑}_{ID}/{章节}_{photoId}/{序号}.png
 * 下载器只登记任务清单并标记「已下载」，不再自己复制或落盘图片。
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
  private library: ComicLibrary | null = null;

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
    this.library = await ComicLibrary.getInstance();
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
    for (let ch of chapters) {
      let taskId = `${albumId}_${ch.photoId}`;
      if (this.tasks.has(taskId)) {
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
    this.tasks.forEach((task: DownloadTask) => {
      if (task.albumId === albumId) {
        // 正在下载的先置暂停，让执行循环在当前图片后停下
        if (task.status === DownloadStatus.DOWNLOADING) {
          task.status = DownloadStatus.PAUSED;
        }
        ids.push(task.taskId);
      }
    });
    for (let id of ids) {
      this.tasks.delete(id);
    }
    if (ids.length > 0) {
      this.notifyUpdate();
      this.processQueue();
    }
    // 连带删除统一仓库中该专辑的图片与清单
    this.library?.removeAlbum(albumId, albumName);
  }

  /** 仅删除整本漫画的仓库图片，保留任务记录（「导出成功后自动删除下载缓存」设置开启时由导出流程调用） */
  deleteAlbumFiles(albumId: number, albumName: string): void {
    this.library?.removeAlbum(albumId, albumName);
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

        if ((task.status as string) === (DownloadStatus.PAUSED as string)) {
          break;
        }
      }
    } finally {
      this.running = false;
    }
  }

  /** 实际执行下载一个章节的所有图片（失败时抛出，由队列标记 ERROR） */
  private async executeDownload(task: DownloadTask): Promise<void> {
    let apiService = ApiService.getInstance();

    // 1. 获取图片列表（含真实 scramble_id）
    let pictureData: PictureData = await apiService.getChapterPictures(task.photoId, task.scrambleId);
    let images: JmImageInfo[] = pictureData.pictures.images;
    let scrambleId: number = pictureData.pictures.scramble_id || task.scrambleId;
    // 与阅读器用同一份元数据构造上下文，命中同一份仓库文件
    let imgNames: string[] = [];
    for (let img of images) {
      imgNames.push(img.img_name);
    }
    let ctx: LibraryContext = {
      albumId: task.albumId,
      albumName: task.albumName,
      photoId: task.photoId,
      chapterName: task.chapterName,
      scrambleId: scrambleId,
      fingerprint: ComicLibrary.chapterFingerprint(scrambleId, imgNames),
      imgNames: imgNames,
    } as LibraryContext;
    task.totalImages = images.length;
    // 章节内容与本地进度不符（服务端改版）时重置进度
    if (task.completedImages > images.length) {
      task.completedImages = 0;
    }
    this.notifyUpdate();

    // 2. 逐张确保图片在统一仓库中（命中阅读缓存/已下载内容时零网络、零复制）
    for (let i = 0; i < images.length; i++) {
      if ((task.status as string) === (DownloadStatus.PAUSED as string)) {
        break;
      }

      let img: JmImageInfo = images[i];
      task.currentImageName = img.img_name;
      this.notifyUpdate();

      try {
        // 断点续传：仓库中已有该文件则直接计入完成
        if (this.library && this.library.hasImage(ctx, i)) {
          if (task.completedImages < i + 1) {
            task.completedImages = i + 1;
            this.notifyUpdate();
          }
          continue;
        }

        await this.downloadImage(ctx, i, img);
        task.completedImages = i + 1;
        this.notifyUpdate();
        DownloadNotifier.notifyProgress(task.albumId, task.albumName, task.chapterName,
          task.completedImages, task.totalImages);
      } catch (err) {
        console.error(`[DownloadService] image failed: ${img.img_name}, ${(err as Error).message}`);
        // 单张失败不中断整体，继续下一张
      }
    }

    // 全部完成后登记为手动下载：永不自动清理
    if (task.completedImages === task.totalImages && this.library) {
      this.library.markDownloaded(ctx);
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
  /**
   * 下载单张图片：只委托统一仓库。
   * 仓库内部完成「查本地 → 旧缓存迁移 → 网络拉取 → scramble 还原 → PNG 落盘 → 记录清单」，
   * 同一图片与阅读/导出共用唯一物理副本，且并发请求自动合并。
   */
  private async downloadImage(ctx: LibraryContext, index: number, img: JmImageInfo): Promise<void> {
    if (!this.library) {
      throw new Error('图片仓库未初始化');
    }
    await this.library.ensureImage(ctx, index, img);
  }

  /** 专辑根目录（兼容旧调用：实际目录由统一仓库管理） */
  getAlbumDir(albumId: number, albumName: string): string {
    return ComicLibrary.albumDir(albumId, albumName);
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

  /** 清理文件名中的非法字符（目录/文件名统一入口） */
  static sanitizeFileName(name: string): string {
    return name.replace(/[\/\\:*?"<>|]/g, '_').trim();
  }
}
