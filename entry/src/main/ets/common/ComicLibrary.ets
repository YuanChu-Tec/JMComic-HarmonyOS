import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { JmImageInfo } from '../models/Album';
import { HttpClient } from '../network/HttpClient';
import { ImageDecodeUtils } from './ImageDecodeUtils';
import { APP_HEADERS_IMAGE } from './Constants';

/**
 * 章节图片清单：决定该章节数据的生命周期
 * downloadedAt > 0 表示手动下载（永不自动清理）；exportedAt > 0 表示已导出（可按策略清理）
 */
export interface ChapterManifest {
  photoId: string;
  albumId: number;
  albumName: string;
  chapterName: string;
  fingerprint: string;
  imgNames: string[];
  lastReadAt: number;
  downloadedAt: number;
  exportedAt: number;
}

/** 调用方传入的章节上下文，阅读/下载两端都从同一份元数据构造 */
export interface LibraryContext {
  albumId: number;
  albumName: string;
  photoId: string;
  chapterName: string;
  scrambleId: number;
  fingerprint: string;
  imgNames: string[];
}

export interface CleanupRule {
  /** 仅阅读、未下载的章节保留天数；0 表示不自动清理 */
  readCacheDays: number;
  /** 已导出章节保留天数；0 表示不自动清理 */
  exportedDays: number;
}

export interface CleanupResult {
  removedChapters: number;
  removedBytes: number;
}

/**
 * 统一漫画图片仓库
 *
 * - 物理目录：filesDir/JMComic/library/{专辑}_{albumId}/{章节}_{photoId}/{序号}.png
 *   阅读、下载、导出共用这唯一一份 PNG，不再互相复制
 * - 写入口唯一：ensureImage() / saveImage()，内部完成网络拉取、scramble 还原、PNG 落盘
 * - 并发去重：同一 photoId/fingerprint/index 的并发请求合并为一个 Promise
 *
 * 注：下载功能尚未发布，无历史数据需要迁移；旧阅读缓存位于 cacheDir，
 * 由系统/设置页「清理缓存」按既有机制处理，仓库不做兼容读取。
 */
export class ComicLibrary {
  private static instance: ComicLibrary | null = null;
  private static staticBaseDir: string = '';
  private baseDir: string = '';
  // 清单独立存放，保证章节目录里只有 PNG，导出 zip 不会混入 manifest.json
  private manifestDir: string = '';
  private manifests: Map<string, ChapterManifest> = new Map<string, ChapterManifest>();
  private inFlight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  private constructor() {
  }

  static async getInstance(): Promise<ComicLibrary> {
    if (ComicLibrary.instance === null) {
      let lib = new ComicLibrary();
      await lib.init();
      ComicLibrary.instance = lib;
    }
    return ComicLibrary.instance;
  }

  static sanitizeFileName(name: string): string {
    return name.replace(/[\/\\:*?"<>|]/g, '_').trim();
  }

  /** 章节指纹：scrambleId + 图片文件名列表（顺序敏感），换图后旧缓存自然失效 */
  static chapterFingerprint(scrambleId: number, imgNames: string[]): string {
    let source: string = `${scrambleId}:`;
    for (let name of imgNames) {
      source += `${name}|`;
    }
    let hash: number = 5381;
    for (let i = 0; i < source.length; i++) {
      hash = ((hash << 5) - hash + source.charCodeAt(i)) | 0;
    }
    return (hash >>> 0).toString(36);
  }

  /** 同步计算专辑目录（ZipExporter 等无仓库实例时使用） */
  static albumDir(albumId: number, albumName: string): string {
    return `${ComicLibrary.staticBaseDir}/${ComicLibrary.sanitizeFileName(albumName)}_${albumId}`;
  }

  private async init(): Promise<void> {
    let ctx = getContext() as common.UIAbilityContext;
    this.baseDir = `${ctx.filesDir}/JMComic/library`;
    this.manifestDir = `${ctx.filesDir}/JMComic/manifests`;
    ComicLibrary.staticBaseDir = this.baseDir;
    if (!fileIo.accessSync(this.baseDir)) {
      fileIo.mkdirSync(this.baseDir, true);
    }
    if (!fileIo.accessSync(this.manifestDir)) {
      fileIo.mkdirSync(this.manifestDir, true);
    }
    await this.scanManifests();
  }

  /** 启动时把所有章节清单读进内存，避免每次查盘 */
  private async scanManifests(): Promise<void> {
    try {
      let names = await fileIo.listFile(this.manifestDir);
      for (let name of names) {
        if (!name.endsWith('.json')) {
          continue;
        }
        try {
          let m = JSON.parse(fileIo.readTextSync(`${this.manifestDir}/${name}`)) as ChapterManifest;
          this.manifests.set(m.photoId, m);
        } catch (e) {
          console.warn(`[ComicLibrary] bad manifest ${name}: ${JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      console.warn(`[ComicLibrary] scan error: ${JSON.stringify(e)}`);
    }
  }

  getAlbumDir(albumId: number, albumName: string): string {
    return `${this.baseDir}/${ComicLibrary.sanitizeFileName(albumName)}_${albumId}`;
  }

  getChapterDir(ctx: LibraryContext): string {
    let safe = ComicLibrary.sanitizeFileName(ctx.chapterName || `第${ctx.photoId}话`);
    // 章节名重复时追加 photoId，避免目录互写
    return `${this.getAlbumDir(ctx.albumId, ctx.albumName)}/${safe}_${ctx.photoId}`;
  }

  getImagePath(ctx: LibraryContext, index: number): string {
    return `${this.getChapterDir(ctx)}/${index + 1}.png`;
  }

  hasImage(ctx: LibraryContext, index: number): boolean {
    return fileIo.accessSync(this.getImagePath(ctx, index));
  }

  /** 从仓库读取已解码图片；未命中返回 null */
  async loadPixelMap(ctx: LibraryContext, index: number): Promise<image.PixelMap | null> {
    try {
      let path = this.getImagePath(ctx, index);
      if (!fileIo.accessSync(path)) {
        return null;
      }
      let src = image.createImageSource(path);
      let pm = await src.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      } as image.DecodingOptions);
      src.release();
      return pm;
    } catch (e) {
      console.warn(`[ComicLibrary] load error ${ctx.photoId}/${index}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /** 保存调用方已解码好的 PixelMap（阅读器预加载/降级加载使用） */
  async saveImage(ctx: LibraryContext, index: number, pixelMap: image.PixelMap): Promise<string> {
    let path = this.getImagePath(ctx, index);
    if (fileIo.accessSync(path)) {
      this.touchManifest(ctx);
      return path;
    }
    this.ensureChapterDir(ctx);
    let packer = image.createImagePacker();
    try {
      let data = await packer.packing(pixelMap, {
        format: 'image/png',
        quality: 100
      } as image.PackingOption);
      let f = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, data);
      fileIo.closeSync(f);
    } finally {
      packer.release();
    }
    this.touchManifest(ctx);
    return path;
  }

  /**
   * 唯一写入口：确保图片在仓库中。
   * 命中直接返回；未命中才网络+解码+落盘；同 key 的并发请求共享同一个 Promise。
   */
  async ensureImage(ctx: LibraryContext, index: number, img: JmImageInfo): Promise<string> {
    let path = this.getImagePath(ctx, index);
    if (fileIo.accessSync(path)) {
      this.touchManifest(ctx);
      return path;
    }
    let key = `${ctx.photoId}/${ctx.fingerprint}/${index}`;
    let pending = this.inFlight.get(key);
    if (pending) {
      return pending;
    }
    let task = this.fetchAndSave(ctx, index, img, path);
    this.inFlight.set(key, task);
    try {
      return await task;
    } finally {
      this.inFlight.delete(key);
    }
  }

  private async fetchAndSave(ctx: LibraryContext, index: number,
    img: JmImageInfo, destPath: string): Promise<string> {
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

    let src = image.createImageSource(data);
    let pm = await src.createPixelMap({
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    } as image.DecodingOptions);
    src.release();
    try {
      let nameNoExt = img.img_name.replace(/\.[^.]+$/, '');
      let num = await ImageDecodeUtils.getSegmentationNum(
        ctx.scrambleId, parseInt(ctx.photoId), nameNoExt);
      if (num > 0) {
        pm = await ImageDecodeUtils.decodeImage(pm, num);
      }
      this.ensureChapterDir(ctx);
      let packer = image.createImagePacker();
      let out = await packer.packing(pm, {
        format: 'image/png',
        quality: 100
      } as image.PackingOption);
      packer.release();
      let f = fileIo.openSync(destPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, out);
      fileIo.closeSync(f);
    } finally {
      pm.release();
    }
    this.touchManifest(ctx);
    return destPath;
  }

  private ensureChapterDir(ctx: LibraryContext): void {
    let dir = this.getChapterDir(ctx);
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
  }

  /** 记录阅读时间并在首次写入时落 manifest.json */
  private touchManifest(ctx: LibraryContext): void {
    let m = this.manifests.get(ctx.photoId);
    if (!m) {
      m = {
        photoId: ctx.photoId,
        albumId: ctx.albumId,
        albumName: ctx.albumName,
        chapterName: ctx.chapterName,
        fingerprint: ctx.fingerprint,
        imgNames: ctx.imgNames,
        lastReadAt: Date.now(),
        downloadedAt: 0,
        exportedAt: 0,
      } as ChapterManifest;
      this.manifests.set(ctx.photoId, m);
    } else {
      m.lastReadAt = Date.now();
    }
    this.writeManifest(ctx, m);
  }

  private writeManifest(ctx: LibraryContext, m: ChapterManifest): void {
    try {
      let path = `${this.manifestDir}/${m.photoId}.json`;
      let f = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(m));
      fileIo.closeSync(f);
    } catch (e) {
      console.warn(`[ComicLibrary] write manifest failed ${ctx.photoId}: ${JSON.stringify(e)}`);
    }
  }

  private deleteManifestFile(photoId: string): void {
    try {
      let path = `${this.manifestDir}/${photoId}.json`;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      console.warn(`[ComicLibrary] delete manifest failed ${photoId}: ${JSON.stringify(e)}`);
    }
  }

  getManifest(photoId: string): ChapterManifest | null {
    return this.manifests.get(photoId) ?? null;
  }

  getAllManifests(): ChapterManifest[] {
    let list: ChapterManifest[] = [];
    this.manifests.forEach((m: ChapterManifest) => list.push(m));
    return list;
  }

  /** 标记为手动下载：永不自动清理 */
  markDownloaded(ctx: LibraryContext): void {
    let m = this.manifests.get(ctx.photoId);
    if (!m) {
      this.touchManifest(ctx);
      m = this.manifests.get(ctx.photoId);
    }
    if (m && m.downloadedAt === 0) {
      m.downloadedAt = Date.now();
      this.writeManifest(ctx, m);
    }
  }

  /** 标记为已导出：可按 exportedDays 策略清理 */
  markExported(photoId: string, exportedAt: number = Date.now()): void {
    let m = this.manifests.get(photoId);
    if (m) {
      m.exportedAt = exportedAt;
      let ctx: LibraryContext = {
        albumId: m.albumId,
        albumName: m.albumName,
        photoId: m.photoId,
        chapterName: m.chapterName,
        scrambleId: 0,
        fingerprint: m.fingerprint,
        imgNames: m.imgNames,
      } as LibraryContext;
      this.writeManifest(ctx, m);
    }
  }

  /** 删除整本漫画的仓库目录并同步移除内存清单（下载管理页删除/导出后清理调用） */
  removeAlbum(albumId: number, albumName: string): void {
    let dir = ComicLibrary.albumDir(albumId, albumName);
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      console.warn(`[ComicLibrary] removeAlbum failed: ${JSON.stringify(e)}`);
    }
    let keys: string[] = [];
    this.manifests.forEach((m: ChapterManifest, key: string) => {
      if (m.albumId === albumId) {
        keys.push(key);
      }
    });
    for (let key of keys) {
      this.manifests.delete(key);
      this.deleteManifestFile(key);
    }
  }

  /** 按清单策略清理过期章节；返回删除章节数与释放字节数 */
  async cleanup(rule: CleanupRule): Promise<CleanupResult> {
    let now = Date.now();
    let toRemove: ChapterManifest[] = [];
    this.manifests.forEach((m: ChapterManifest) => {
      if (m.downloadedAt === 0 && rule.readCacheDays > 0
        && now - m.lastReadAt > rule.readCacheDays * 24 * 60 * 60 * 1000) {
        toRemove.push(m);
      } else if (m.downloadedAt > 0 && m.exportedAt > 0 && rule.exportedDays > 0
        && now - m.exportedAt > rule.exportedDays * 24 * 60 * 60 * 1000) {
        toRemove.push(m);
      }
    });
    return await this.removeChapters(toRemove);
  }

  /**
   * 手动强制清空图片仓库：不按保留天数过滤，删除全部章节图片与清单。
   * 仅影响 filesDir/JMComic/library 与 manifests，阅读位置等 preferences 数据不受影响。
   */
  async clearAll(): Promise<CleanupResult> {
    let all: ChapterManifest[] = [];
    this.manifests.forEach((m: ChapterManifest) => all.push(m));
    return await this.removeChapters(all);
  }

  /** 删除指定章节的仓库目录与清单文件 */
  private async removeChapters(list: ChapterManifest[]): Promise<CleanupResult> {
    let result: CleanupResult = { removedChapters: 0, removedBytes: 0 } as CleanupResult;
    for (let m of list) {
      let ctx: LibraryContext = {
        albumId: m.albumId,
        albumName: m.albumName,
        photoId: m.photoId,
        chapterName: m.chapterName,
        scrambleId: 0,
        fingerprint: m.fingerprint,
        imgNames: m.imgNames,
      } as LibraryContext;
      let dir = this.getChapterDir(ctx);
      try {
        if (fileIo.accessSync(dir)) {
          result.removedBytes += await this.dirSize(dir);
          await fileIo.rmdir(dir);
        }
        this.manifests.delete(m.photoId);
        this.deleteManifestFile(m.photoId);
        result.removedChapters++;
      } catch (e) {
        console.warn(`[ComicLibrary] remove chapter failed ${m.photoId}: ${JSON.stringify(e)}`);
      }
    }
    return result;
  }

  private async dirSize(dir: string): Promise<number> {
    let total = 0;
    let names = await fileIo.listFile(dir);
    for (let name of names) {
      let full = `${dir}/${name}`;
      let stat = await fileIo.stat(full);
      total += stat.isDirectory() ? await this.dirSize(full) : stat.size;
    }
    return total;
  }

  /** 仓库总字节数，供设置页展示 */
  async totalSize(): Promise<number> {
    return await this.dirSize(this.baseDir);
  }
}
