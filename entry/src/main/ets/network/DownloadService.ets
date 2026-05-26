import { fileIo } from '@kit.CoreFileKit';
import { HttpClient } from './HttpClient';
import { ApiService } from './ApiService';
import {
  DownloadTask,
  DownloadStatus,
  JmImageInfo,
  IDownloadTaskJSON,
} from '../models/Album';
import { APP_HEADERS_IMAGE } from '../common/Constants';
import { CacheManager } from '../common/CacheManager';

/**
 * 下载服务
 * 管理下载队列，支持暂停/继续/删除
 * 对应 Python: JmDownloader
 * 对应 QT: DownloadStatus + task_download
 */
export class DownloadService {
  private tasks: Map<string, DownloadTask> = new Map();
  private running: boolean = false;
  /** 回调：任务状态变化时通知 UI */
  onTaskUpdated: (() => void) | null = null;
  /** 同时下载任务数 */
  private concurrentCount: number = 1;
  private activeCount: number = 0;
  private cache: CacheManager | null = null;

  /** 初始化缓存 */
  async initCache(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    // 从缓存恢复任务
    let raw = this.cache.loadDownloadTasks();
    try {
      let items = JSON.parse(raw) as IDownloadTaskJSON[];
      for (let item of items) {
        let task = DownloadTask.fromJSON(item);
        // 恢复非终态任务为暂停状态
        if (task.status === DownloadStatus.DOWNLOADING || task.status === DownloadStatus.QUEUED) {
          task.status = DownloadStatus.PAUSED;
        }
        this.tasks.set(task.taskId, task);
      }
    } catch {
      // ignore parse errors
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
   * 添加章节下载任务
   * @param apiService 用于获取图片列表
   * @param albumId 专辑ID
   * @param albumName 专辑名
   * @param photoId 章节ID
   * @param chapterName 章节名
   * @param scrambleId 加密ID
   */
  addTask(
    albumId: number,
    albumName: string,
    photoId: string,
    chapterName: string,
    scrambleId: number
  ): DownloadTask {
    let taskId = `${albumId}_${photoId}`;
    if (this.tasks.has(taskId)) {
      return this.tasks.get(taskId)!;
    }

    let task = new DownloadTask();
    task.taskId = taskId;
    task.albumId = albumId;
    task.albumName = albumName;
    task.photoId = photoId;
    task.chapterName = chapterName;
    task.scrambleId = scrambleId;
    task.status = DownloadStatus.QUEUED;
    task.addTime = Date.now();
    this.tasks.set(taskId, task);

    this.notifyUpdate();
    this.processQueue();
    return task;
  }

  /** 暂停任务 */
  pauseTask(taskId: string): void {
    let task = this.tasks.get(taskId);
    if (task && task.status === DownloadStatus.DOWNLOADING) {
      task.status = DownloadStatus.PAUSED;
      this.activeCount--;
      this.notifyUpdate();
    }
  }

  /** 继续任务 */
  resumeTask(taskId: string): void {
    let task = this.tasks.get(taskId);
    if (task && task.status === DownloadStatus.PAUSED) {
      task.status = DownloadStatus.QUEUED;
      this.notifyUpdate();
      this.processQueue();
    }
  }

  /** 删除任务 */
  removeTask(taskId: string): void {
    let task = this.tasks.get(taskId);
    if (task && task.status === DownloadStatus.DOWNLOADING) {
      task.status = DownloadStatus.PAUSED;
      this.activeCount--;
    }
    this.tasks.delete(taskId);
    this.notifyUpdate();
    this.processQueue();
  }

  /** 处理下载队列 */
  async processQueue(): Promise<void> {
    if (this.running) return;
    this.running = true;

    try {
      while (this.hasPendingTasks()) {
        // 找到下一个排队任务
        let task = this.getNextQueuedTask();
        if (!task) break;

        this.activeCount++;
        task.status = DownloadStatus.DOWNLOADING;
        this.notifyUpdate();

        try {
          await this.executeDownload(task);
          // 下载完成
          if (task.status === DownloadStatus.DOWNLOADING) {
            task.status = DownloadStatus.DONE;
          }
        } catch (err) {
          if ((task.status as string) !== (DownloadStatus.PAUSED as string)) {
            task.status = DownloadStatus.ERROR;
            task.errorMsg = (err as Error).message || '未知错误';
          }
        } finally {
          this.activeCount--;
          this.notifyUpdate();
        }

        // 检查是否被暂停
        if ((task.status as string) === (DownloadStatus.PAUSED as string)) {
          break;
        }
      }
    } finally {
      this.running = false;
    }
  }

  /** 实际执行下载一个章节的所有图片 */
  private async executeDownload(task: DownloadTask): Promise<void> {
    let apiService = new ApiService();
    try {
      // 1. 获取图片列表
      let pictureData = await apiService.getChapterPictures(task.photoId, task.scrambleId);
      let images = pictureData.pictures.images;
      let scrambleId = pictureData.pictures.scramble_id;
      task.totalImages = images.length;
      task.completedImages = 0;
      this.notifyUpdate();

      // 2. 创建目录
      let dirPath = this.getDownloadDir(task);
      if (!fileIo.accessSync(dirPath)) {
        fileIo.mkdirSync(dirPath, true);
      }

      // 3. 逐张下载
      for (let i = 0; i < images.length; i++) {
        if ((task.status as string) === (DownloadStatus.PAUSED as string)) {
          break;
        }

        let img = images[i];
        task.currentImageName = img.img_name;
        this.notifyUpdate();

        try {
          await this.downloadImage(img, dirPath, scrambleId);
          task.completedImages = i + 1;
          this.notifyUpdate();
        } catch (err) {
          console.error(`[DownloadService] image failed: ${img.img_name}, ${(err as Error).message}`);
          // 单张失败不中断整体，继续下一张
        }
      }
    } finally {
      apiService.destroy();
    }
  }

  /** 下载单张图片并保存到文件 */
  private async downloadImage(img: JmImageInfo, dirPath: string, _scrambleId: number): Promise<void> {
    let url = img.download_url || img.img_url;
    let headers: Record<string, string> = HttpClient.mergeHeaders(APP_HEADERS_IMAGE, {});

    // 下载二进制数据，若失败则重试一次
    let data: ArrayBuffer;
    try {
      data = await HttpClient.downloadBinary(url, headers);
    } catch (err) {
      // 第一次失败，等待后重试
      await HttpClient.sleep(2000);
      data = await HttpClient.downloadBinary(url, headers);
    }

    // 写入文件
    let filePath = `${dirPath}/${this.sanitizeFileName(img.img_name)}`;
    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    fileIo.writeSync(file.fd, data);
    fileIo.closeSync(file);
  }

  /** 下载目录 */
  private getDownloadDir(task: DownloadTask): string {
    let baseDir = this.getBaseDir();
    return `${baseDir}/${task.albumName}_${task.albumId}/${task.chapterName}_${task.photoId}`;
  }

  /** 基础下载目录 */
  private getBaseDir(): string {
    return '/data/storage/el2/base/cache/JMComic/download';
  }

  /** 安全的文件名 */
  private sanitizeFileName(name: string): string {
    return name.replace(/[/\\:*?"<>|]/g, '_');
  }

  // ─── 队列管理 ───

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

  private notifyUpdate(): void {
    this.syncToCache();
    if (this.onTaskUpdated) {
      this.onTaskUpdated();
    }
  }
}
