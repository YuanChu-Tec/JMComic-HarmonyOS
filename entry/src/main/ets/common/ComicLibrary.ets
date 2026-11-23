import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { ChapterManifest } from '../models/Album';
import { JmImageInfo, JmPictureResp } from '../models/dto/ApiDto';
import { HttpClient } from '../network/HttpClient';
import { ImageDecodeUtils } from './ImageDecodeUtils';
import { APP_HEADERS_IMAGE } from './Constants';
import { ComicAlbumStore } from '../models/ComicAlbum';

/**
 * 章节元数据副本：服务器 /chapter 返回的稳定内容（不含实时统计、不含用户态）
 * 存于章节目录的 meta.json，记录「当前这组 PNG 对应哪份元数据」
 */
export interface ChapterMeta {
  photoId: string;
  scrambleId: number;
  imgNames: string[];
  fingerprint: string;
  updatedAt: number;
}

/** 章节上下文：阅读/下载两端都从同一份服务器元数据构造 */
export interface LibraryContext {
  albumId: number;
  albumName: string;
  photoId: string;
  chapterName: string;
  scrambleId: number;
  /** 元数据指纹 = chapterFingerprint(scrambleId, imgNames) */
  fingerprint: string;
  imgNames: string[];
}

export interface CleanupRule {
  readCacheDays: number;
  exportedDays: number;
}

export interface CleanupResult {
  removedChapters: number;
  removedBytes: number;
}

/**
 * 统一漫画图片仓库（逐页原子替换）
 *
 * 目录结构：
 *   filesDir/JMComic/albums/{albumId}/chapters/{章节}_{photoId}/
 *     meta.json          → 当前这组 PNG 对应的服务器元数据（scrambleId + imgNames）
 *     originals/{imgName}→ 服务器原始图片（webp/jpg，原名）
 *     1.png … N.png      → 已解码 PNG
 *   albums/{albumId}/manifests/{photoId}.json → 生命周期清单（跟随漫画目录）
 *
 * 写入策略：
 * - 每页独立写入：先写 `{name}.tmp`，再 rename 覆盖目标，保证任何时刻读到的都是完整文件
 * - 换版（fingerprint 变化）时逐页替换：已替换的页即新图，未替换的页仍是完整旧图，
 *   用户始终可读，不会出现整章空白
 * - meta.json 在整章替换完成后写入，标记这组图已对应新元数据
 */
export class ComicLibrary {
  private static instance: ComicLibrary | null = null;
  private static staticBaseDir: string = '';
  private baseDir: string = '';
  private manifests: Map<string, ChapterManifest> = new Map<string, ChapterManifest>();
  private inFlight: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** 章节目录元数据的内存副本，避免预加载逐页读盘解析 */
  private metaCache: Map<string, ChapterMeta> = new Map<string, ChapterMeta>();

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

  /**
   * 元数据指纹：scrambleId + 图片文件名列表（顺序敏感）。
   * 不含 img_url —— 多域名容灾时域名会变但图片内容不变，算进去会误判。
   */
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

  static imageNamesOf(resp: JmPictureResp): string[] {
    let names: string[] = [];
    for (let img of resp.images) {
      names.push(img.img_name);
    }
    return names;
  }

  /** 同步计算专辑目录：与 ComicAlbumStore 的实体目录合并 */
  static albumDir(albumId: number, albumName: string): string {
    return ComicAlbumStore.albumRoot(albumId);
  }

  private async init(): Promise<void> {
    let ctx = getContext() as common.UIAbilityContext;
    this.baseDir = `${ctx.filesDir}/JMComic/albums`;
    ComicLibrary.staticBaseDir = this.baseDir;
    if (!fileIo.accessSync(this.baseDir)) fileIo.mkdirSync(this.baseDir, true);
    await this.scanManifests();
  }

  /** 某部漫画的清单目录（跟随漫画目录，一章一个文件） */
  private getManifestDir(albumId: number): string {
    return `${ComicAlbumStore.albumRoot(albumId)}/manifests`;
  }

  /** 启动时扫描各漫画目录下的清单，读进内存避免每次查盘 */
  private async scanManifests(): Promise<void> {
    try {
      if (!fileIo.accessSync(this.baseDir)) return;
      let albums = await fileIo.listFile(this.baseDir);
      for (let album of albums) {
        let dir = `${this.baseDir}/${album}/manifests`;
        if (!fileIo.accessSync(dir)) continue;
        let names = await fileIo.listFile(dir);
        for (let name of names) {
          if (!name.endsWith('.json')) continue;
          try {
            let m = JSON.parse(fileIo.readTextSync(`${dir}/${name}`)) as ChapterManifest;
            this.manifests.set(m.photoId, m);
          } catch (e) {
            console.warn(`[ComicLibrary] bad manifest ${album}/${name}: ${JSON.stringify(e)}`);
          }
        }
      }
    } catch (e) {
      console.warn(`[ComicLibrary] scan error: ${JSON.stringify(e)}`);
    }
  }

  // ─── 路径 ───

  getAlbumDir(albumId: number, albumName: string): string {
    return ComicLibrary.albumDir(albumId, albumName);
  }

  getChapterDir(ctx: LibraryContext): string {
    let safe = ComicLibrary.sanitizeFileName(ctx.chapterName || `第${ctx.photoId}话`);
    return `${this.getAlbumDir(ctx.albumId, ctx.albumName)}/chapters/${safe}_${ctx.photoId}`;
  }

  private getMetaPath(ctx: LibraryContext): string {
    return `${this.getChapterDir(ctx)}/meta.json`;
  }

  /** 解码后的 PNG 路径（与 images[i] 一一对应） */
  getImagePath(ctx: LibraryContext, index: number): string {
    return `${this.getChapterDir(ctx)}/${index + 1}.png`;
  }

  /** 服务器原始图片目录（按 img_name 原名存放 webp/jpg） */
  getOriginalsDir(ctx: LibraryContext): string {
    return `${this.getChapterDir(ctx)}/originals`;
  }

  hasImage(ctx: LibraryContext, index: number): boolean {
    return fileIo.accessSync(this.getImagePath(ctx, index));
  }

  // ─── 原子写 ───

  /**
   * 原子写文件：先写临时文件，再 rename 覆盖目标。
   * 读取方任何时刻拿到的都是完整的旧文件或完整的新文件，不会读到写了一半的内容。
   */
  private atomicWrite(path: string, data: ArrayBuffer | string): void {
    let tmp = `${path}.tmp`;
    let out = fileIo.openSync(tmp,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(out.fd, data);
    } finally {
      fileIo.closeSync(out);
    }
    // rename 不能覆盖已存在目标，先删旧文件；这一瞬间的窗口极小，
    // 读取方拿不到文件会降级走网络，而不会读到损坏的半张图
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
    fileIo.renameSync(tmp, path);
  }

  // ─── 读 ───

  async loadPixelMap(ctx: LibraryContext, index: number): Promise<image.PixelMap | null> {
    try {
      let path = this.getImagePath(ctx, index);
      if (!fileIo.accessSync(path)) return null;
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

  /** 读取当前章节目录已落盘 PNG 对应的元数据（内存优先，避免逐页读盘） */
  getChapterMeta(ctx: LibraryContext): ChapterMeta | null {
    let cached = this.metaCache.get(ctx.photoId);
    if (cached) return cached;
    try {
      let path = this.getMetaPath(ctx);
      if (!fileIo.accessSync(path)) return null;
      let meta = JSON.parse(fileIo.readTextSync(path)) as ChapterMeta;
      this.metaCache.set(ctx.photoId, meta);
      return meta;
    } catch (e) {
      console.warn(`[ComicLibrary] read meta failed ${ctx.photoId}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /**
   * 读取当前已落盘版本的上下文（供「本地秒显」用）。
   * 优先用 meta.json（真实反映磁盘上的图），缺失时退回清单。
   */
  getCurrentContext(photoId: string): LibraryContext | null {
    let m = this.manifests.get(photoId);
    if (!m) return null;
    let ctx: LibraryContext = {
      albumId: m.albumId,
      albumName: m.albumName,
      photoId: m.photoId,
      chapterName: m.chapterName,
      scrambleId: m.scrambleId || 0,
      fingerprint: m.fingerprint,
      imgNames: m.imgNames,
    } as LibraryContext;
    let meta = this.getChapterMeta(ctx);
    if (meta && meta.imgNames.length > 0) {
      // 以磁盘元数据为准：它记录的是「这组 PNG 实际对应的内容」
      ctx.scrambleId = meta.scrambleId;
      ctx.fingerprint = meta.fingerprint || ComicLibrary.chapterFingerprint(meta.scrambleId, meta.imgNames);
      ctx.imgNames = meta.imgNames;
    }
    return ctx;
  }

  /** 元数据是否与当前落盘版本不同（需要逐页替换） */
  isMetaChanged(ctx: LibraryContext): boolean {
    let m = this.manifests.get(ctx.photoId);
    if (!m) return true;
    return m.fingerprint !== ctx.fingerprint;
  }

  /** 该章节已落盘的图片数 */
  cachedImageCount(ctx: LibraryContext): number {
    let count = 0;
    for (let i = 0; i < ctx.imgNames.length; i++) {
      if (fileIo.accessSync(this.getImagePath(ctx, i))) count++;
    }
    return count;
  }

  // ─── 写 ───

  /**
   * 确保某页存在且内容正确（逐页替换的最小单元）。
   * - 该页文件名与解码参数都没变、且文件已在盘上 → 直接复用
   * - 否则下载并原子覆盖这一页，其它页不受影响
   *
   * 注意：整章指纹变化不代表每一页都变了，这里按「页」判断，
   * 只替换真正变化的页；替换过程中其它页始终是完整的旧图，可正常阅读。
   */
  async ensureImage(ctx: LibraryContext, index: number, img: JmImageInfo): Promise<string> {
    let path = this.getImagePath(ctx, index);
    let meta = this.getChapterMeta(ctx);
    let samePage = meta !== null
      && meta.scrambleId === ctx.scrambleId
      && index < meta.imgNames.length
      && meta.imgNames[index] === img.img_name;
    if (samePage && fileIo.accessSync(path)) {
      this.touchManifest(ctx);
      return path;
    }
    return await this.fetchPage(ctx, index, img, path);
  }

  /**
   * 整章所有页处理完成后调用：写入该章元数据并同步清单。
   * 中途退出不会写 meta，下次进入仍按「逐页」判断，已替换的页不会重复下载。
   */
  commitChapter(ctx: LibraryContext): void {
    this.writeMeta(ctx);
    this.updateManifestMeta(ctx);
    // 新元数据页数少于旧版时删除多余页，避免残留旧图
    this.removeExtraPages(ctx, ctx.imgNames.length);
  }

  private async fetchPage(ctx: LibraryContext, index: number,
    img: JmImageInfo, destPath: string): Promise<string> {
    let key = `${ctx.photoId}/${ctx.fingerprint}/${index}`;
    let pending = this.inFlight.get(key);
    if (pending) return pending;
    let task = this.downloadAndEncode(ctx, index, img, destPath);
    this.inFlight.set(key, task);
    try {
      return await task;
    } finally {
      this.inFlight.delete(key);
    }
  }

  private async downloadAndEncode(ctx: LibraryContext, index: number,
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

    this.ensureChapterDir(ctx);
    // 原始图片按原名原子落盘
    let originalsDir = this.getOriginalsDir(ctx);
    if (!fileIo.accessSync(originalsDir)) fileIo.mkdirSync(originalsDir, true);
    try {
      this.atomicWrite(`${originalsDir}/${img.img_name}`, data);
    } catch (e) {
      console.warn(`[ComicLibrary] save original failed ${ctx.photoId}/${img.img_name}: ${JSON.stringify(e)}`);
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
      let packer = image.createImagePacker();
      let out = await packer.packing(pm, {
        format: 'image/png',
        quality: 100
      } as image.PackingOption);
      packer.release();
      // 逐页原子替换：写完即可被读到，读到的永远是完整图
      this.atomicWrite(destPath, out);
    } finally {
      pm.release();
    }
    this.touchManifest(ctx);
    return destPath;
  }

  private ensureChapterDir(ctx: LibraryContext): void {
    let dir = this.getChapterDir(ctx);
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
  }

  private writeMeta(ctx: LibraryContext): void {
    try {
      this.ensureChapterDir(ctx);
      let meta: ChapterMeta = {
        photoId: ctx.photoId,
        scrambleId: ctx.scrambleId,
        imgNames: ctx.imgNames,
        fingerprint: ctx.fingerprint,
        updatedAt: Date.now(),
      } as ChapterMeta;
      this.atomicWrite(this.getMetaPath(ctx), JSON.stringify(meta));
      this.metaCache.set(ctx.photoId, meta);
    } catch (e) {
      console.warn(`[ComicLibrary] write meta failed ${ctx.photoId}: ${JSON.stringify(e)}`);
    }
  }

  /** 删除 index > count 的残留页（换版后页数变少时） */
  private removeExtraPages(ctx: LibraryContext, count: number): void {
    try {
      let dir = this.getChapterDir(ctx);
      if (!fileIo.accessSync(dir)) return;
      let names = fileIo.listFileSync(dir);
      for (let name of names) {
        if (!name.endsWith('.png')) continue;
        let idx = parseInt(name.replace(/\.png$/, ''));
        if (!isNaN(idx) && idx > count) {
          fileIo.unlinkSync(`${dir}/${name}`);
        }
      }
    } catch (e) {
      console.warn(`[ComicLibrary] remove extra pages failed ${ctx.photoId}: ${JSON.stringify(e)}`);
    }
  }

  private updateManifestMeta(ctx: LibraryContext): void {
    let m = this.manifests.get(ctx.photoId);
    if (!m) {
      this.touchManifest(ctx);
      return;
    }
    m.fingerprint = ctx.fingerprint;
    m.scrambleId = ctx.scrambleId;
    m.imgNames = ctx.imgNames;
    m.lastReadAt = Date.now();
    this.writeManifest(ctx, m);
  }

  // ─── 清单与生命周期 ───

  private touchManifest(ctx: LibraryContext): void {
    let m = this.manifests.get(ctx.photoId);
    if (!m) {
      m = {
        photoId: ctx.photoId,
        albumId: ctx.albumId,
        albumName: ctx.albumName,
        chapterName: ctx.chapterName,
        fingerprint: ctx.fingerprint,
        scrambleId: ctx.scrambleId,
        imgNames: ctx.imgNames,
        lastReadAt: Date.now(),
        downloadedAt: 0,
        exportedAt: 0,
      } as ChapterManifest;
      this.manifests.set(ctx.photoId, m);
    } else {
      m.lastReadAt = Date.now();
      // 章节名可能被用户重命名/服务端改名，保持与当前上下文一致
      m.albumId = ctx.albumId;
      m.albumName = ctx.albumName;
      m.chapterName = ctx.chapterName;
    }
    this.writeManifest(ctx, m);
  }

  private writeManifest(ctx: LibraryContext, m: ChapterManifest): void {
    try {
      let dir = this.getManifestDir(m.albumId);
      if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
      this.atomicWrite(`${dir}/${m.photoId}.json`, JSON.stringify(m));
    } catch (e) {
      console.warn(`[ComicLibrary] write manifest failed ${ctx.photoId}: ${JSON.stringify(e)}`);
    }
  }

  private deleteManifestFile(albumId: number, photoId: string): void {
    try {
      let path = `${this.getManifestDir(albumId)}/${photoId}.json`;
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
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

  markExported(photoId: string, exportedAt: number = Date.now()): void {
    let m = this.manifests.get(photoId);
    if (m) {
      m.exportedAt = exportedAt;
      let ctx = this.ctxOfManifest(m);
      this.writeManifest(ctx, m);
    }
  }

  private ctxOfManifest(m: ChapterManifest): LibraryContext {
    return {
      albumId: m.albumId,
      albumName: m.albumName,
      photoId: m.photoId,
      chapterName: m.chapterName,
      scrambleId: m.scrambleId || 0,
      fingerprint: m.fingerprint,
      imgNames: m.imgNames,
    } as LibraryContext;
  }

  /** 删除整部漫画的仓库目录（实体 + PNG + 清单全部删除） */
  removeAlbum(albumId: number, albumName: string): void {
    let dir = ComicLibrary.albumDir(albumId, albumName);
    try {
      if (fileIo.accessSync(dir)) fileIo.rmdirSync(dir);
    } catch (e) {
      console.warn(`[ComicLibrary] removeAlbum failed: ${JSON.stringify(e)}`);
    }
    this.removeManifestsOf(albumId);
  }

  /** 仅删除该漫画的章节图片（保留 album.json 实体）；用于「导出后自动删除下载缓存」 */
  removeAlbumImages(albumId: number, albumName: string): void {
    let root = ComicLibrary.albumDir(albumId, albumName);
    let chaptersDir = `${root}/chapters`;
    try {
      if (fileIo.accessSync(chaptersDir)) fileIo.rmdirSync(chaptersDir);
    } catch (e) {
      console.warn(`[ComicLibrary] removeAlbumImages failed: ${JSON.stringify(e)}`);
    }
    this.removeManifestsOf(albumId);
  }

  private removeManifestsOf(albumId: number): void {
    let keys: string[] = [];
    this.manifests.forEach((m: ChapterManifest, key: string) => {
      if (m.albumId === albumId) keys.push(key);
    });
    for (let key of keys) {
      this.manifests.delete(key);
      this.metaCache.delete(key);
    }
    try {
      let dir = this.getManifestDir(albumId);
      if (fileIo.accessSync(dir)) fileIo.rmdirSync(dir);
    } catch (e) {
      console.warn(`[ComicLibrary] remove manifests failed ${albumId}: ${JSON.stringify(e)}`);
    }
  }

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

  async clearAll(): Promise<CleanupResult> {
    let all: ChapterManifest[] = [];
    this.manifests.forEach((m: ChapterManifest) => all.push(m));
    return await this.removeChapters(all);
  }

  private async removeChapters(list: ChapterManifest[]): Promise<CleanupResult> {
    let result: CleanupResult = { removedChapters: 0, removedBytes: 0 } as CleanupResult;
    for (let m of list) {
      let ctx = this.ctxOfManifest(m);
      let dir = this.getChapterDir(ctx);
      try {
        if (fileIo.accessSync(dir)) {
          result.removedBytes += await this.dirSize(dir);
          await fileIo.rmdir(dir);
        }
        this.manifests.delete(m.photoId);
        this.metaCache.delete(m.photoId);
        this.deleteManifestFile(m.albumId, m.photoId);
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

  async totalSize(): Promise<number> {
    return await this.dirSize(this.baseDir);
  }

  /**
   * 构建导出用 staging 目录：把该专辑的 PNG 复制成扁平结构
   *   {stagingRoot}/{章节名}/{序号}.png
   * 不含 meta.json / originals 等内部文件，保证 zip 内层级干净。
   * @returns 实际写入的章节目录数
   */
  async buildExportStage(albumId: number, albumName: string, stagingRoot: string): Promise<number> {
    if (fileIo.accessSync(stagingRoot)) {
      await fileIo.rmdir(stagingRoot);
    }
    fileIo.mkdirSync(stagingRoot, true);
    let chapters = 0;
    for (let m of this.manifests.values()) {
      if (m.albumId !== albumId) continue;
      let ctx = this.ctxOfManifest(m);
      let safe = ComicLibrary.sanitizeFileName(m.chapterName || `第${m.photoId}话`);
      let destDir = `${stagingRoot}/${safe}`;
      fileIo.mkdirSync(destDir, true);
      let count = 0;
      for (let i = 0; i < m.imgNames.length; i++) {
        let src = this.getImagePath(ctx, i);
        if (!fileIo.accessSync(src)) continue;
        let dst = `${destDir}/${i + 1}.png`;
        let sf = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
        let df = fileIo.openSync(dst,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.copyFileSync(sf.fd, df.fd);
        } finally {
          fileIo.closeSync(sf);
          fileIo.closeSync(df);
        }
        count++;
      }
      if (count > 0) chapters++;
    }
    return chapters;
  }
}
