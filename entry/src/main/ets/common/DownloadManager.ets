import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { ApiService } from '../network/ApiService';
import { ImageDecodeUtils } from './ImageDecodeUtils';
import { DecodedImageCache } from './DecodedImageCache';
import { APP_HEADERS_IMAGE } from './Constants';
import { JmImageInfo, PictureData } from '../models/Album';

export interface ChapterDownloadInfo {
  photoId: string;
  photoName: string;
  scrambleId: number;
}

export class DownloadManager {
  private static instance: DownloadManager | null = null;
  private apiService: ApiService = ApiService.getInstance();
  private decodedCache: DecodedImageCache | null = null;
  private downloadDir: string = '';
  private isDownloading: boolean = false;
  private cancelled: boolean = false;
  private currentRequest: http.HttpRequest | null = null;

  private constructor() {
  }

  static async getInstance(): Promise<DownloadManager> {
    if (DownloadManager.instance === null) {
      DownloadManager.instance = new DownloadManager();
      await DownloadManager.instance.init();
    }
    return DownloadManager.instance;
  }

  private async init(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    this.downloadDir = `${context.filesDir}/JMComic`;
    this.decodedCache = await DecodedImageCache.getInstance();
  }

  getIsDownloading(): boolean {
    return this.isDownloading;
  }

  cancelDownload(): void {
    this.cancelled = true;
    // 中断正在进行的 HTTP 请求
    if (this.currentRequest) {
      try {
        this.currentRequest.destroy();
      } catch (_e) {}
      this.currentRequest = null;
    }
  }

  /**
   * 下载整本漫画所有章节
   */
  async downloadAlbum(
    albumName: string,
    chapters: ChapterDownloadInfo[],
    baseDir: string,
    onProgress: (current: number, total: number, chapterName: string) => void,
    onComplete: (success: number, failed: number) => void,
    onError: (msg: string) => void
  ): Promise<void> {
    if (this.isDownloading) {
      onError('正在下载中，请稍候');
      return;
    }
    this.isDownloading = true;
    this.cancelled = false;

    // 清理文件名中的非法字符
    let safeAlbumName = this.sanitizeFileName(albumName);
    let albumDir = `${baseDir}/${safeAlbumName}`;

    let totalImages = 0;
    let successCount = 0;
    let failedCount = 0;
    let currentProcessed = 0;

    try {
      // 第一遍：统计总图片数
      let chapterDataList: PictureData[] = [];
      for (let chapter of chapters) {
        try {
          let data = await this.apiService.getChapterPictures(chapter.photoId, chapter.scrambleId);
          chapterDataList.push(data);
          if (data.pictures && data.pictures.images) {
            totalImages += data.pictures.images.length;
          }
        } catch (e) {
          console.error(`[DownloadManager] getChapterPictures failed for ${chapter.photoId}: ${JSON.stringify(e)}`);
          chapterDataList.push({} as PictureData);
        }
      }

      if (totalImages === 0) {
        onError('无法获取图片信息');
        this.isDownloading = false;
        return;
      }

      // 第二遍：逐章逐图下载
      for (let chIdx = 0; chIdx < chapters.length; chIdx++) {
        if (this.cancelled) {
          break;
        }

        let chapter = chapters[chIdx];
        let data = chapterDataList[chIdx];

        if (!data.pictures || !data.pictures.images) {
          failedCount++;
          continue;
        }

        let safeChapterName = this.sanitizeFileName(chapter.photoName || `第${chIdx + 1}话`);
        let chapterDir = `${albumDir}/${safeChapterName}`;
        this.ensureDir(chapterDir);

        let images = data.pictures.images;
        let scrambleId = data.pictures.scramble_id || chapter.scrambleId;

        for (let imgIdx = 0; imgIdx < images.length; imgIdx++) {
          try {
            let destPath = `${chapterDir}/${imgIdx + 1}.png`;
            // 目标文件已存在则跳过
            if (fileIo.accessSync(destPath)) {
              successCount++;
              currentProcessed++;
              onProgress(currentProcessed, totalImages, safeChapterName);
              continue;
            }

            let ok = await this.downloadImage(
              chapter.photoId, imgIdx, scrambleId, images[imgIdx], destPath
            );
            if (ok) {
              successCount++;
            } else {
              failedCount++;
            }
          } catch (e) {
            console.error(`[DownloadManager] download image failed ${chapter.photoId}/${imgIdx}: ${JSON.stringify(e)}`);
            failedCount++;
          }
          currentProcessed++;
          onProgress(currentProcessed, totalImages, safeChapterName);

          if (this.cancelled) {
            onComplete(successCount, failedCount);
            this.isDownloading = false;
            return;
          }
        }
      }

      onComplete(successCount, failedCount);
    } catch (err) {
      let errMsg = err instanceof Error ? err.message : JSON.stringify(err);
      onError(errMsg || '下载失败');
    } finally {
      this.isDownloading = false;
    }
  }

  /**
   * 下载单张图片（优先复制缓存 → 降级网络下载）
   */
  private async downloadImage(
    photoId: string, index: number,
    scrambleId: number, img: JmImageInfo,
    destPath: string
  ): Promise<boolean> {
    // 1. 优先从 decoded cache 复制
    if (this.decodedCache && this.decodedCache.hasCached(photoId, index)) {
      let cachePath = this.decodedCache.getCacheFilePath(photoId, index);
      try {
        fileIo.copyFileSync(cachePath, destPath);
        console.info(`[DownloadManager] copied from cache: ${photoId}/${index}`);
        return true;
      } catch (e) {
        console.warn(`[DownloadManager] copy from cache failed: ${JSON.stringify(e)}`);
      }
    }

    // 2. 缓存未命中，网络下载+解码+保存
    let url = img.img_url || img.download_url;
    if (!url || url.length === 0) {
      return false;
    }

    try {
      let request = http.createHttp();
      this.currentRequest = request;
      let response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: APP_HEADERS_IMAGE,
        connectTimeout: 15000,
        readTimeout: 30000,
      });

      if (response.responseCode !== 200) {
        this.currentRequest = null;
        request.destroy();
        return false;
      }

      let arrayBuffer = response.result as ArrayBuffer;
      this.currentRequest = null;
      request.destroy();

      // 解码为 PixelMap
      let imageSource = image.createImageSource(arrayBuffer);
      let pixelMap = await imageSource.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      imageSource.release();

      // scramble 解码
      let imgNameNoExt = img.img_name.replace(/\.[^.]+$/, '');
      let num = await ImageDecodeUtils.getSegmentationNum(
        scrambleId,
        parseInt(photoId),
        imgNameNoExt
      );
      if (num > 0) {
        pixelMap = await ImageDecodeUtils.decodeImage(pixelMap, num);
      }

      // 保存到目标路径
      await this.savePixelMapToFile(pixelMap, destPath);

      // 顺便写入 decoded cache
      if (this.decodedCache) {
        this.decodedCache.saveDecodedImage(photoId, index, pixelMap);
      }

      pixelMap.release();
      console.info(`[DownloadManager] downloaded and saved: ${photoId}/${index}`);
      return true;
    } catch (e) {
      console.error(`[DownloadManager] download failed ${photoId}/${index}: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 将 PixelMap 保存为 PNG 文件
   */
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

  /**
   * 清理文件名中的非法字符
   */
  private sanitizeFileName(name: string): string {
    return name.replace(/[\/\\:*?"<>|]/g, '_').trim();
  }

  /**
   * 确保目录存在
   */
  private ensureDir(dirPath: string): void {
    if (!fileIo.accessSync(dirPath)) {
      fileIo.mkdirSync(dirPath, true);
    }
  }
}
