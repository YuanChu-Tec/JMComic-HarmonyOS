import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';

/**
 * 已解码图片的磁盘缓存
 * 路径格式：cacheDir/decoded/{photoId}/{index}.png
 * 后台预加载：下载 + 拼图解码 + 写 PNG → release
 * 前台懒加载：从磁盘 PNG 创建 PixelMap → 显示
 * 滑出视口时释放内存，滑回时从磁盘秒加载
 */
export class DecodedImageCache {
  private static instance: DecodedImageCache | null = null;
  private baseDir: string = '';

  private constructor() {
  }

  static async getInstance(): Promise<DecodedImageCache> {
    if (DecodedImageCache.instance === null) {
      DecodedImageCache.instance = new DecodedImageCache();
      await DecodedImageCache.instance.initDir();
    }
    return DecodedImageCache.instance;
  }

  private async initDir(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    this.baseDir = `${context.cacheDir}/decoded`;
    if (!fileIo.accessSync(this.baseDir)) {
      fileIo.mkdirSync(this.baseDir, true);
    }
  }

  private getChapterDir(photoId: string): string {
    return `${this.baseDir}/${photoId}`;
  }

  private getFilePath(photoId: string, index: number): string {
    return `${this.baseDir}/${photoId}/${index}.png`;
  }

  private ensureChapterDir(photoId: string): void {
    let dir = this.getChapterDir(photoId);
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
  }

  /**
   * 将已解码的 PixelMap 保存为 PNG 到磁盘
   */
  async saveDecodedImage(photoId: string, index: number, pixelMap: image.PixelMap): Promise<void> {
    try {
      this.ensureChapterDir(photoId);
      let filePath = this.getFilePath(photoId, index);
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
    } catch (e) {
      console.warn(`[DecodedImageCache] save failed ${photoId}/${index}: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 从磁盘加载已解码图片为 PixelMap
   * 返回 null 表示缓存未命中
   */
  async loadDecodedImage(photoId: string, index: number): Promise<image.PixelMap | null> {
    try {
      let filePath = this.getFilePath(photoId, index);
      if (!fileIo.accessSync(filePath)) {
        return null;
      }
      let imageSource = image.createImageSource(filePath);
      let decodeOpts: image.DecodingOptions = {
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      let pixelMap = await imageSource.createPixelMap(decodeOpts);
      imageSource.release();
      return pixelMap;
    } catch (e) {
      console.warn(`[DecodedImageCache] load failed ${photoId}/${index}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /**
   * 获取缓存文件路径（供外部复制用）
   */
  getCacheFilePath(photoId: string, index: number): string {
    return this.getFilePath(photoId, index);
  }

  /**
   * 检查磁盘缓存是否存在
   */
  hasCached(photoId: string, index: number): boolean {
    let filePath = this.getFilePath(photoId, index);
    return fileIo.accessSync(filePath);
  }

  /**
   * 删除某个章节的所有缓存（删除整个 photoId 目录）
   */
  deleteChapterCache(photoId: string): void {
    try {
      let dir = this.getChapterDir(photoId);
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      console.warn(`[DecodedImageCache] delete chapter cache failed: ${JSON.stringify(e)}`);
    }
  }
}
