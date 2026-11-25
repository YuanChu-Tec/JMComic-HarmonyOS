import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { JmImageInfo, JmPictureResp } from '../models/dto/ApiDto';
import { HttpClient } from '../network/HttpClient';
import { ImageDecodeUtils } from './ImageDecodeUtils';
import { APP_HEADERS_IMAGE } from './Constants';
import { AlbumDao } from '../storage/AlbumDao';
import { ProgressDao } from '../storage/ProgressDao';
import { CacheManager } from './CacheManager';

/**
 * 章节磁盘记录，写在章节目录的 meta.json 里，一目录一份。
 *
 * fingerprint / imgNames 只由 commitChapter 写（整章对齐完成才算），
 * 因此 meta.json 既是「这版图已对齐」的提交标记，也是启动扫描重建索引的唯一来源。
 * albumId / albumName / chapterName / downloadedAt 是索引信息，跟着目录走。
 */
export interface ChapterMeta {
  photoId: string;
  albumId: number;
  albumName: string;
  chapterName: string;
  /** 当前已落盘 PNG 用的解码参数（换版时与 imgNames 一起参与比对） */
  scrambleId: number;
  imgNames: string[];
  /** 元数据指纹 = hash(scrambleId + imgNames)，仅作「哪一次拉取」的提交标记 */
  fingerprint: string;
  /** 手动下载时间，0 表示只是阅读缓存；随目录一起删，故与文件同处 */
  downloadedAt: number;
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
 * 目录结构（一目录一条记录，没有平行的索引目录）：
 *   filesDir/JMComic/albums/{albumId}/chapters/{章节}_{photoId}/
 *     meta.json          → 这组 PNG 对应的元数据 + 是否手动下载（提交标记）
 *     1.png … N.png      → 已解码 PNG
 *
 * 可重建的中间产物不占 filesDir：
 *   cacheDir/JMComic/originals/{photoId}/{imgName} → 服务器原始图片（webp/jpg，原名）
 * 它只是 PNG 的原料，系统回收或「清理缓存」删掉都不影响阅读，缺了下次再下。
 *
 * 专辑目录本身还放封面：
 *   filesDir/JMComic/albums/{albumId}/cover{size}-{ver}.jpg → 封面图（ver 由封面名算出）
 *   filesDir/JMComic/albums/{albumId}/cover{size}.jpg       → 无版本名（关闭封面刷新时用）
 * 由 static cover* 方法管理，与章节图同生命周期，removeAlbum 一起删。
 *
 * meta.json 既是「这版图已对齐」的提交标记，也是启动扫描重建索引的唯一来源：
 * 删目录即删记录，不会出现清单在而目录不在、或目录在而清单不在的中间态。
 * 目录存在但没有 meta.json 说明是逐页下载中断，仍按目录名建索引，可被清理。
 *
 * 用户态事实不落在这里：已导出时间在 pref（exported_{albumId}），最后阅读时间在 read_state。
 *
 * 写入策略：
 * - 每页独立写入：先写 `{name}.tmp`，再 rename 覆盖目标，保证任何时刻读到的都是完整文件
 * - 换版由设置页「刷新内容·图片」开关决定：开启时比对 meta.json 里这一页的
 *   img_name / scramble_id，变了就重下覆盖；关闭时本地有就一直用
 * - meta.json 在整章处理完成后写入，作为「这组图来自某次拉取」的提交标记
 *
 * 启动扫描顺带清理非产物文件（rename 前崩溃留下的 .tmp、旧版 cover{size}.name），
 * 因此 filesDir 里稳定只有 PNG、meta.json、封面三类。
 */
export class ComicLibrary {
  private static instance: ComicLibrary | null = null;
  private static staticBaseDir: string = '';
  private baseDir: string = '';
  /** 可重建的中间产物（服务器原始图）放这里：系统或「清理缓存」随时可删，删了不影响阅读 */
  private cacheBaseDir: string = '';
  private inFlight: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /**
   * 章节索引：photoId → 磁盘记录，启动扫描 chapters 目录重建，之后读写都在内存。
   * fingerprint 为空表示该目录还没有提交记录（下载中断），不代表磁盘上的图属于某个版本。
   */
  private metaCache: Map<string, ChapterMeta> = new Map<string, ChapterMeta>();
  /** 清理规则要读的用户态事实（已导出时间、最后阅读时间）都在 SQL，不在清单文件里 */
  private cache: CacheManager | null = null;
  private progress: ProgressDao | null = null;

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

  /** 同步计算专辑目录：与 AlbumDao 的实体目录合并 */
  static albumDir(albumId: number, albumName: string): string {
    return AlbumDao.albumRoot(albumId);
  }

  /** 专辑目录（不需要专辑名；封面等静态调用也走这里） */
  static albumDirOf(albumId: number): string {
    return AlbumDao.albumRoot(albumId);
  }

  // ─── 封面 ───
  // 封面文件名带版本：cover{size}-{hash(image_name)}.jpg。
  // 设置页「刷新内容·封面」开启时，刷新拿到的 image_name 一变就落到新文件名，
  // 旧文件随即失效并重下；关闭时退回无版本名 cover{size}.jpg，永久沿用旧图。
  // 必须是 static：coverSource() 在 build() 里同步取值，等不了 getInstance() 的 async init。

  /** 正在下载的封面路径，避免同图重复请求 */
  private static coverInflight: Set<string> = new Set<string>();

  /** 无版本名的封面路径（关闭封面刷新时用，也是历史文件名） */
  static coverPath(albumId: string | number, size: string): string {
    return `${ComicLibrary.albumDirOf(Number(albumId))}/cover${size}.jpg`;
  }

  /** 版本标识：封面名未知时返回空串，退化为无版本文件 */
  private static coverVersion(imageName: string): string {
    if (imageName === '') return '';
    let hash = 5381;
    for (let i = 0; i < imageName.length; i++) {
      hash = ((hash << 5) - hash + imageName.charCodeAt(i)) | 0;
    }
    return (hash >>> 0).toString(36);
  }

  /** 某专辑某尺寸的当前封面路径：有版本时 cover{size}-{ver}.jpg */
  static coverPathOf(albumId: string | number, size: string, imageName: string): string {
    let ver = ComicLibrary.coverVersion(imageName);
    if (ver === '') return ComicLibrary.coverPath(albumId, size);
    return `${ComicLibrary.albumDirOf(Number(albumId))}/cover${size}-${ver}.jpg`;
  }

  /**
   * 本地可用返回 file:// URI；文件缺失返回空串。
   * 服务器换了封面名时，旧图是否继续用由「刷新内容·封面」的间隔决定：
   * 未到间隔沿用旧图，到期返回空串让调用方下载新版本。
   */
  static coverLocalUri(albumId: string | number, size: string, imageName: string = ''): string {
    let path = ComicLibrary.coverPathOf(albumId, size, imageName);
    if (fileIo.accessSync(path)) return `file://${path}`;
    // 拿不到封面名（如下载管理页）或目录里没有旧图时，只能按无版本文件兜底
    let cached = ComicLibrary.findCover(albumId, size);
    if (cached === '' || imageName === '') return cached;
    return ComicLibrary.coverDue(cached) ? '' : cached;
  }

  /** 旧封面是否到了换版时间：MAX 永不换，-1 每次都换，其余按文件修改时间 */
  private static coverDue(localUri: string): boolean {
    if (AlbumDao.coverTtlMs === Number.MAX_SAFE_INTEGER) return false;
    if (AlbumDao.coverTtlMs < 0) return true;
    try {
      let stat = fileIo.statSync(localUri.replace('file://', ''));
      return Date.now() - stat.mtime * 1000 >= AlbumDao.coverTtlMs;
    } catch (e) {
      return true;
    }
  }

  /** 目录里已有的同尺寸封面（cover{size}.jpg 或 cover{size}-*.jpg），没有返回空串 */
  private static findCover(albumId: string | number, size: string): string {
    let dir = ComicLibrary.albumDirOf(Number(albumId));
    let base = `cover${size}`;
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return '';
    }
    for (let name of names) {
      if (!name.endsWith('.jpg')) continue;
      if (name !== `${base}.jpg` && !name.startsWith(`${base}-`)) continue;
      return `file://${dir}/${name}`;
    }
    return '';
  }

  /** 本地没有当前版本的封面时下载一次；已有同版本文件一律不重下 */
  static ensureCover(albumId: string | number, size: string, url: string,
    imageName: string = ''): void {
    let path = ComicLibrary.coverPathOf(albumId, size, imageName);
    if (fileIo.accessSync(path)) return;
    if (ComicLibrary.coverInflight.has(path)) return;
    ComicLibrary.coverInflight.add(path);
    HttpClient.downloadBinary(url, APP_HEADERS_IMAGE)
      .then((data: ArrayBuffer) => {
        if (data.byteLength > 0) ComicLibrary.writeCover(albumId, size, data, imageName);
      })
      .catch((err: Error) => {
        console.warn(`[ComicLibrary] cover download failed ${albumId}${size}: ${JSON.stringify(err)}`);
      })
      .finally(() => {
        ComicLibrary.coverInflight.delete(path);
      });
  }

  private static writeCover(albumId: string | number, size: string, data: ArrayBuffer,
    imageName: string): void {
    let path = ComicLibrary.coverPathOf(albumId, size, imageName);
    try {
      let dir = ComicLibrary.albumDirOf(Number(albumId));
      if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
      ComicLibrary.atomicWrite(path, data);
    } catch (err) {
      console.warn(`[ComicLibrary] cover write failed ${path}: ${JSON.stringify(err)}`);
      return;
    }
    ComicLibrary.dropOtherCovers(albumId, size, path);
  }

  /** 换版后删掉同尺寸的其它封面文件，避免残留在盘上白占体积 */
  private static dropOtherCovers(albumId: string | number, size: string, keep: string): void {
    let dir = ComicLibrary.albumDirOf(Number(albumId));
    let base = `cover${size}`;
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let name of names) {
      if (!name.endsWith('.jpg')) continue;
      if (name !== `${base}.jpg` && !name.startsWith(`${base}-`)) continue;
      let full = `${dir}/${name}`;
      if (full === keep) continue;
      try {
        fileIo.unlinkSync(full);
      } catch (e) {
        console.warn(`[ComicLibrary] drop stale cover failed ${full}: ${JSON.stringify(e)}`);
      }
    }
  }

  /** 旧版本的 cover{size}.name 索引：已无任何读取方，扫到就删 */
  private static removeLegacyCoverNames(albumRoot: string): void {
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(albumRoot);
    } catch (e) {
      return;
    }
    for (let name of names) {
      if (!name.startsWith('cover') || !name.endsWith('.name')) continue;
      try {
        fileIo.unlinkSync(`${albumRoot}/${name}`);
      } catch (e) {
        console.warn(`[ComicLibrary] remove legacy cover name failed ${name}: ${JSON.stringify(e)}`);
      }
    }
  }

  /**
   * 清掉原子写崩溃残留的 {name}.tmp。
   * atomicWrite 先写 .tmp 再 rename，进程若死在两者之间就会留下半份文件；
   * 读取方从不看 .tmp，所以留在盘上只会白占体积。
   */
  private static removeTmpFiles(dir: string): void {
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let name of names) {
      if (!name.endsWith('.tmp')) continue;
      try {
        fileIo.unlinkSync(`${dir}/${name}`);
      } catch (e) {
        console.warn(`[ComicLibrary] remove tmp failed ${name}: ${JSON.stringify(e)}`);
      }
    }
  }

  private async init(): Promise<void> {
    let ctx = getContext() as common.UIAbilityContext;
    this.baseDir = `${ctx.filesDir}/JMComic/albums`;
    ComicLibrary.staticBaseDir = this.baseDir;
    this.cacheBaseDir = `${ctx.cacheDir}/JMComic/originals`;
    if (!fileIo.accessSync(this.baseDir)) fileIo.mkdirSync(this.baseDir, true);
    this.cache = await CacheManager.getInstance();
    this.progress = await ProgressDao.getInstance();
    await this.scanLibrary();
  }

  /** 章节目录名 = {安全章节名}_{photoId}，photoId 在最后一段 */
  private static photoIdOfDir(dirName: string): string {
    let pos = dirName.lastIndexOf('_');
    if (pos < 0) return '';
    let id = dirName.substring(pos + 1);
    return id.length > 0 && !Number.isNaN(Number(id)) ? id : '';
  }

  private static chapterNameOfDir(dirName: string, photoId: string): string {
    let pos = dirName.lastIndexOf('_');
    return pos > 0 ? dirName.substring(0, pos) : `第${photoId}话`;
  }

  /** 老格式 meta.json 缺字段时补默认值；不做业务判断 */
  private static normalizeMeta(raw: ChapterMeta): ChapterMeta {
    return {
      photoId: raw.photoId || '',
      albumId: raw.albumId || 0,
      albumName: raw.albumName || '',
      chapterName: raw.chapterName || '',
      scrambleId: raw.scrambleId || 0,
      imgNames: raw.imgNames || [],
      fingerprint: raw.fingerprint || '',
      downloadedAt: raw.downloadedAt || 0,
      updatedAt: raw.updatedAt || 0,
    } as ChapterMeta;
  }

  /**
   * 启动时扫 chapters 目录重建索引。
   * meta.json 是唯一记录来源；目录存在但没有 meta.json 的，按目录名建一条未提交记录。
   */
  private async scanLibrary(): Promise<void> {
    try {
      if (!fileIo.accessSync(this.baseDir)) return;
      let albumDirs = await fileIo.listFile(this.baseDir);
      for (let albumDirName of albumDirs) {
        let albumId = Number(albumDirName);
        if (Number.isNaN(albumId)) continue;
        let albumRoot = `${this.baseDir}/${albumDirName}`;
        // 崩溃残留的 .tmp、旧版封面索引：都不是最终产物，扫到就清
        ComicLibrary.removeTmpFiles(albumRoot);
        ComicLibrary.removeLegacyCoverNames(albumRoot);
        let legacy = this.readLegacyManifests(albumRoot);
        let chaptersDir = `${albumRoot}/chapters`;
        if (fileIo.accessSync(chaptersDir)) {
          let dirs = await fileIo.listFile(chaptersDir);
          for (let dirName of dirs) {
            let dir = `${chaptersDir}/${dirName}`;
            try {
              if (!fileIo.statSync(dir).isDirectory()) continue;
            } catch (e) {
              continue;
            }
            let photoId = ComicLibrary.photoIdOfDir(dirName);
            if (!photoId) continue;
            // 旧版本把原始图放在 filesDir，现已移到 cacheDir：扫到就清，避免仓库体积虚高
            ComicLibrary.removeLegacyOriginals(dir);
            ComicLibrary.removeTmpFiles(dir);
            this.indexChapter(albumId, photoId, dirName, dir, legacy.get(photoId));
          }
        }
        // 旧版一章一个 json 的清单目录：信息已并入 meta.json，迁移后删除
        ComicLibrary.removeLegacyDir(albumRoot);
      }
    } catch (e) {
      console.warn(`[ComicLibrary] scan error: ${JSON.stringify(e)}`);
    }
  }

  /** 读旧版 manifests 目录（仅迁移时用来补 albumName / downloadedAt，读完即删） */
  private readLegacyManifests(albumRoot: string): Map<string, ChapterMeta> {
    let map: Map<string, ChapterMeta> = new Map<string, ChapterMeta>();
    let dir = `${albumRoot}/manifests`;
    if (!fileIo.accessSync(dir)) return map;
    try {
      let names = fileIo.listFileSync(dir);
      for (let name of names) {
        if (!name.endsWith('.json')) continue;
        try {
          let raw = JSON.parse(fileIo.readTextSync(`${dir}/${name}`)) as ChapterMeta;
          if (raw && raw.photoId) map.set(raw.photoId, ComicLibrary.normalizeMeta(raw));
        } catch (e) {
          console.warn(`[ComicLibrary] bad legacy manifest ${name}: ${JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      console.warn(`[ComicLibrary] read legacy manifests failed: ${JSON.stringify(e)}`);
    }
    return map;
  }

  private static removeLegacyDir(albumRoot: string): void {
    let dir = `${albumRoot}/manifests`;
    try {
      if (fileIo.accessSync(dir)) fileIo.rmdirSync(dir);
    } catch (e) {
      console.warn(`[ComicLibrary] remove legacy manifests failed: ${JSON.stringify(e)}`);
    }
  }

  /** 旧版本的原始图目录在章节目录下，已迁到 cacheDir */
  private static removeLegacyOriginals(chapterDir: string): void {
    let dir = `${chapterDir}/originals`;
    try {
      if (fileIo.accessSync(dir)) fileIo.rmdirSync(dir);
    } catch (e) {
      console.warn(`[ComicLibrary] remove legacy originals failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 索引一个章节目录。有 meta.json 就是提交记录；没有则是下载中断，
   * 只依据目录名建一条未提交记录（不写 meta.json，否则会伪造「已对齐」）。
   */
  private indexChapter(albumId: number, photoId: string, dirName: string,
    dir: string, legacy: ChapterMeta | undefined): void {
    let meta: ChapterMeta | null = null;
    let metaPath = `${dir}/meta.json`;
    if (fileIo.accessSync(metaPath)) {
      try {
        meta = ComicLibrary.normalizeMeta(JSON.parse(fileIo.readTextSync(metaPath)) as ChapterMeta);
      } catch (e) {
        console.warn(`[ComicLibrary] bad meta ${dir}: ${JSON.stringify(e)}`);
      }
    }
    if (meta === null || meta.fingerprint === '') {
      this.metaCache.set(photoId, {
        photoId: photoId,
        albumId: albumId,
        albumName: legacy ? legacy.albumName : '',
        chapterName: meta && meta.chapterName ? meta.chapterName
          : ComicLibrary.chapterNameOfDir(dirName, photoId),
        scrambleId: 0,
        imgNames: [] as string[],
        fingerprint: '',
        downloadedAt: legacy ? legacy.downloadedAt : 0,
        updatedAt: 0,
      } as ChapterMeta);
      return;
    }
    let changed = false;
    if (!meta.photoId) {
      meta.photoId = photoId;
      changed = true;
    }
    if (!meta.albumId) {
      meta.albumId = albumId;
      changed = true;
    }
    if (!meta.chapterName) {
      meta.chapterName = ComicLibrary.chapterNameOfDir(dirName, photoId);
      changed = true;
    }
    if (!meta.albumName && legacy !== undefined) {
      meta.albumName = legacy.albumName;
      changed = true;
    }
    // 旧版清单里的手动下载标记并进来，否则升级后已下载内容会被当成阅读缓存清掉
    if (meta.downloadedAt === 0 && legacy !== undefined && legacy.downloadedAt > 0) {
      meta.downloadedAt = legacy.downloadedAt;
      changed = true;
    }
    this.metaCache.set(photoId, meta);
    if (changed) this.writeMetaFile(dir, meta);
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

  /**
   * 服务器原始图片目录（按 img_name 原名存放 webp/jpg）。
   * 放 cacheDir：它只是「PNG 的原料」，属于可重建数据，系统回收或「清理缓存」删掉都无妨，
   * 下次阅读 PNG 时再下一份即可。不对应任何用户资产，故不参与 filesDir 的体积/保留策略。
   */
  getOriginalsDir(ctx: LibraryContext): string {
    return `${this.cacheBaseDir}/${ctx.photoId}`;
  }

  hasImage(ctx: LibraryContext, index: number): boolean {
    return fileIo.accessSync(this.getImagePath(ctx, index));
  }

  // ─── 原子写 ───

  /**
   * 原子写文件：先写临时文件，再 rename 覆盖目标。
   * 读取方任何时刻拿到的都是完整的旧文件或完整的新文件，不会读到写了一半的内容。
   * 封面与章节图共用这一份实现，所以是 static。
   */
  private static atomicWrite(path: string, data: ArrayBuffer | string): void {
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
    // fingerprint 为空表示只有目录、没有提交记录，不能当作「已对齐某个版本」
    if (cached && cached.fingerprint) return cached;
    try {
      let path = this.getMetaPath(ctx);
      if (!fileIo.accessSync(path)) return null;
      let meta = ComicLibrary.normalizeMeta(JSON.parse(fileIo.readTextSync(path)) as ChapterMeta);
      if (!meta.fingerprint) return null;
      this.metaCache.set(ctx.photoId, meta);
      return meta;
    } catch (e) {
      console.warn(`[ComicLibrary] read meta failed ${ctx.photoId}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /** 读取当前已落盘版本的上下文（供「本地秒显」用）；索引项就是磁盘 meta.json 的内容 */
  getCurrentContext(photoId: string): LibraryContext | null {
    let m = this.metaCache.get(photoId);
    if (!m) return null;
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
   * 确保某页存在：本地有这一页就直接用，没有才下载并原子落盘。
   * 已落盘章节比对这一页的 img_name（及 scramble_id），服务器换图才重下；
   * 是否重新嗅探受「刷新内容·章节图片」间隔约束——未到期或设为「不自动」时本地有就一直用。
   * 未提交的章节（下载中断）指纹为空，按同一批处理，不重复下载已完成页。
   */
  async ensureImage(ctx: LibraryContext, index: number, img: JmImageInfo): Promise<string> {
    let path = this.getImagePath(ctx, index);
    if (fileIo.accessSync(path)) {
      let meta = this.getChapterMeta(ctx);
      if (meta === null
        || !CacheManager.contentDue(CacheManager.CONTENT_IMAGE, meta.updatedAt)
        || !ComicLibrary.pageChanged(meta, ctx, index, img.img_name)) {
        this.ensureChapterIndex(ctx);
        return path;
      }
      return await this.fetchPage(ctx, index, img, path);
    }
    return await this.fetchPage(ctx, index, img, path);
  }

  /** 已落盘版本里这一页是否与服务器当前元数据不同（scramble_id 未知时不参与比较） */
  private static pageChanged(meta: ChapterMeta, ctx: LibraryContext,
    index: number, imgName: string): boolean {
    if (meta.imgNames[index] !== imgName) return true;
    return meta.scrambleId > 0 && ctx.scrambleId > 0 && meta.scrambleId !== ctx.scrambleId;
  }

  /**
   * 整章所有页处理完成后调用：把提交记录写进章节目录的 meta.json。
   * 中途退出不会写 meta，下次进入仍按「逐页」判断，已替换的页不会重复下载。
   */
  commitChapter(ctx: LibraryContext): void {
    let m = this.metaCache.get(ctx.photoId);
    let meta: ChapterMeta = {
      photoId: ctx.photoId,
      albumId: ctx.albumId,
      albumName: ctx.albumName,
      chapterName: ctx.chapterName,
      scrambleId: ctx.scrambleId,
      imgNames: ctx.imgNames,
      fingerprint: ctx.fingerprint,
      downloadedAt: m ? m.downloadedAt : 0,
      updatedAt: Date.now(),
    } as ChapterMeta;
    this.ensureChapterDir(ctx);
    this.writeMetaFile(this.getChapterDir(ctx), meta);
    this.metaCache.set(ctx.photoId, meta);
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
      ComicLibrary.atomicWrite(`${originalsDir}/${img.img_name}`, data);
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
      ComicLibrary.atomicWrite(destPath, out);
    } finally {
      pm.release();
    }
    this.ensureChapterIndex(ctx);
    return destPath;
  }

  private ensureChapterDir(ctx: LibraryContext): void {
    let dir = this.getChapterDir(ctx);
    if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
  }

  /**
   * 确保索引里有这一章（纯内存操作，不写盘）。
   * meta.json 只在整章对齐完成后由 commitChapter 写，保持提交标记的语义；
   * 首次落盘靠目录本身存在即可，重启后由 scanLibrary 重建。
   */
  private ensureChapterIndex(ctx: LibraryContext): void {
    let m = this.metaCache.get(ctx.photoId);
    if (m === undefined) {
      this.metaCache.set(ctx.photoId, {
        photoId: ctx.photoId,
        albumId: ctx.albumId,
        albumName: ctx.albumName,
        chapterName: ctx.chapterName,
        scrambleId: 0,
        imgNames: [] as string[],
        fingerprint: '',
        downloadedAt: 0,
        updatedAt: 0,
      } as ChapterMeta);
      return;
    }
    if (m.albumId === ctx.albumId && m.albumName === ctx.albumName
      && m.chapterName === ctx.chapterName) {
      return;
    }
    // 服务端改名：索引跟着上下文走，已提交的章节同步落盘
    m.albumId = ctx.albumId;
    m.albumName = ctx.albumName;
    m.chapterName = ctx.chapterName;
    if (m.fingerprint) this.writeMetaFile(this.getChapterDir(ctx), m);
  }

  /** 一个章节目录的提交记录：只有这里会写 meta.json */
  private writeMetaFile(dir: string, meta: ChapterMeta): void {
    try {
      ComicLibrary.atomicWrite(`${dir}/meta.json`, JSON.stringify(meta));
    } catch (e) {
      console.warn(`[ComicLibrary] write meta failed ${meta.photoId}: ${JSON.stringify(e)}`);
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

  // ─── 生命周期 ───

  /** 标记为手动下载：不受阅读缓存规则清理，只有导出后 N 天才清 */
  markDownloaded(ctx: LibraryContext): void {
    let m = this.metaCache.get(ctx.photoId);
    if (m === undefined) {
      this.ensureChapterIndex(ctx);
      m = this.metaCache.get(ctx.photoId);
    }
    if (m === undefined || m.downloadedAt > 0) return;
    m.downloadedAt = Date.now();
    m.albumId = ctx.albumId;
    m.albumName = ctx.albumName;
    m.chapterName = ctx.chapterName;
    if (m.fingerprint) this.writeMetaFile(this.getChapterDir(ctx), m);
  }

  private ctxOfMeta(m: ChapterMeta): LibraryContext {
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

  /** 删除整部漫画的仓库目录（PNG + meta.json + 封面一起删，记录随目录消失） */
  removeAlbum(albumId: number, albumName: string): void {
    let dir = ComicLibrary.albumDir(albumId, albumName);
    let photoIds = this.photoIdsOfAlbum(albumId);
    try {
      if (fileIo.accessSync(dir)) fileIo.rmdirSync(dir);
    } catch (e) {
      console.warn(`[ComicLibrary] removeAlbum failed: ${JSON.stringify(e)}`);
    }
    this.dropIndexOf(albumId);
    for (let id of photoIds) {
      this.dropOriginals(id);
    }
  }

  /** 仅删除该漫画的章节图片（保留专辑目录）；用于「导出后自动删除下载缓存」 */
  removeAlbumImages(albumId: number, albumName: string): void {
    let root = ComicLibrary.albumDir(albumId, albumName);
    let chaptersDir = `${root}/chapters`;
    let photoIds = this.photoIdsOfAlbum(albumId);
    try {
      if (fileIo.accessSync(chaptersDir)) fileIo.rmdirSync(chaptersDir);
    } catch (e) {
      console.warn(`[ComicLibrary] removeAlbumImages failed: ${JSON.stringify(e)}`);
    }
    ComicLibrary.removeLegacyDir(root);
    this.dropIndexOf(albumId);
    for (let id of photoIds) {
      this.dropOriginals(id);
    }
  }

  private dropIndexOf(albumId: number): void {
    let keys: string[] = [];
    this.metaCache.forEach((m: ChapterMeta, key: string) => {
      if (m.albumId === albumId) keys.push(key);
    });
    for (let key of keys) {
      this.metaCache.delete(key);
    }
  }

  /**
   * 按规则清理，判定与删除的粒度都是「一整部漫画」：
   * - 阅读缓存：把整本各章的「阅读时间 or 目录写入时间」取最大作为该漫画的活跃时间，
   *   超期就把整本的非手动下载章节一起删，不留下零散几章；
   * - 已导出内容：导出时间本身就是整本的，超期就整本的手动下载章节一起删。
   *
   * 用户态时间都来自 SQL：最后阅读时间 → read_state（tick 与 read_at 取大），
   * 导出时间 → pref 的 exported_{albumId}；目录只提供「有什么、是否手动下载」。
   * 清理只删图片，阅读记录（已读标记、页码、最后阅读章节）全部保留。
   */
  async cleanup(rule: CleanupRule): Promise<CleanupResult> {
    let now = Date.now();
    let day = 24 * 60 * 60 * 1000;
    let toRemove: ChapterMeta[] = [];
    // 按专辑分组，一部漫画只查两次库，而不是每章一次
    let byAlbum: Map<number, ChapterMeta[]> = new Map<number, ChapterMeta[]>();
    this.metaCache.forEach((m: ChapterMeta) => {
      let list = byAlbum.get(m.albumId);
      if (!list) {
        list = [];
        byAlbum.set(m.albumId, list);
      }
      list.push(m);
    });
    byAlbum.forEach((list: ChapterMeta[], albumId: number) => {
      let exportedAt = this.cache ? this.cache.getAlbumExportedAt(albumId) : 0;
      let reads: Map<string, number> = this.progress
        ? this.progress.lastActivityOfAlbum(albumId) : new Map<string, number>();
      // 整本活跃时间只由阅读缓存章节决定（手动下载的章节归导出规则管）；
      // 目录 mtime 兜底保证正在下载、刚缓存的漫画不会被当成旧缓存
      let activeAt = 0;
      for (let m of list) {
        if (m.downloadedAt > 0) continue;
        let at = Math.max(reads.get(m.photoId) ?? 0, this.dirModifiedAt(this.ctxOfMeta(m)));
        if (at > activeAt) activeAt = at;
      }
      let readExpired = rule.readCacheDays > 0 && activeAt > 0
        && now - activeAt > rule.readCacheDays * day;
      let exportedExpired = exportedAt > 0 && rule.exportedDays > 0
        && now - exportedAt > rule.exportedDays * day;
      for (let m of list) {
        if (m.downloadedAt === 0) {
          if (readExpired) toRemove.push(m);
        } else if (exportedExpired) {
          toRemove.push(m);
        }
      }
    });
    return await this.removeChapters(toRemove);
  }

  /** 目录最后写入时间（毫秒）；这是磁盘事实，不是第二份用户态时间 */
  private dirModifiedAt(ctx: LibraryContext): number {
    try {
      let dir = this.getChapterDir(ctx);
      if (!fileIo.accessSync(dir)) return 0;
      return fileIo.statSync(dir).mtime * 1000;
    } catch (e) {
      return 0;
    }
  }

  async clearAll(): Promise<CleanupResult> {
    let all: ChapterMeta[] = [];
    this.metaCache.forEach((m: ChapterMeta) => all.push(m));
    let result = await this.removeChapters(all);
    // 章节删完后专辑目录里还留着封面，一并清掉，否则「清空图片仓库」后体积不为 0
    if (fileIo.accessSync(this.baseDir)) {
      let dirs = await fileIo.listFile(this.baseDir);
      for (let name of dirs) {
        let dir = `${this.baseDir}/${name}`;
        try {
          result.removedBytes += await this.dirSize(dir);
          await fileIo.rmdir(dir);
        } catch (e) {
          console.warn(`[ComicLibrary] clearAll dir failed ${name}: ${JSON.stringify(e)}`);
        }
      }
    }
    // 原始图快照在 cacheDir，不属于图片仓库体积，但「清空图片仓库」时一并清掉
    try {
      if (fileIo.accessSync(this.cacheBaseDir)) fileIo.rmdirSync(this.cacheBaseDir);
    } catch (e) {
      console.warn(`[ComicLibrary] clear originals failed: ${JSON.stringify(e)}`);
    }
    return result;
  }

  private async removeChapters(list: ChapterMeta[]): Promise<CleanupResult> {
    let result: CleanupResult = { removedChapters: 0, removedBytes: 0 } as CleanupResult;
    for (let m of list) {
      let ctx = this.ctxOfMeta(m);
      let dir = this.getChapterDir(ctx);
      try {
        if (fileIo.accessSync(dir)) {
          result.removedBytes += await this.dirSize(dir);
          await fileIo.rmdir(dir);
        }
        // 目录删成功才删索引：失败时留待下次重试，不会出现「记录没了、文件还在」
        this.metaCache.delete(m.photoId);
        this.dropOriginals(m.photoId);
        result.removedChapters++;
      } catch (e) {
        console.warn(`[ComicLibrary] remove chapter failed ${m.photoId}: ${JSON.stringify(e)}`);
      }
    }
    return result;
  }

  /** 删该章的原始图快照（在 cacheDir，不存在就忽略） */
  private dropOriginals(photoId: string): void {
    let dir = `${this.cacheBaseDir}/${photoId}`;
    try {
      if (fileIo.accessSync(dir)) fileIo.rmdirSync(dir);
    } catch (e) {
      console.warn(`[ComicLibrary] drop originals failed ${photoId}: ${JSON.stringify(e)}`);
    }
  }

  /** 该专辑在索引里的所有 photoId（删 originals 用，必须在 dropIndexOf 之前取） */
  private photoIdsOfAlbum(albumId: number): string[] {
    let ids: string[] = [];
    this.metaCache.forEach((m: ChapterMeta) => {
      if (m.albumId === albumId) ids.push(m.photoId);
    });
    return ids;
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
    for (let m of this.metaCache.values()) {
      // 未提交（下载中断）的目录没有可导出的完整版本，直接跳过，不留空目录
      if (m.albumId !== albumId || m.imgNames.length === 0) continue;
      let ctx = this.ctxOfMeta(m);
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
