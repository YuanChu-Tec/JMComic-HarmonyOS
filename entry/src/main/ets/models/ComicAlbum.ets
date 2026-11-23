import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { JmAlbumDetail, JmAlbumSeries, JmPictureResp, RespJmAlbumInfo } from './dto/ApiDto';

/**
 * 统一漫画实体（数据模型）
 *
 * 一部漫画的固有数据：身份、简介、作者分类、章节目录。
 * 不含实时统计（views/likes/comments）与用户态（favorite/liked/阅读位置/下载状态）。
 *
 * 原始字段保真：author 用数组、category 用原始结构、封面用文件名；
 * 显示字段（authorText/categoryText/chapterCount）由派生函数计算，不落盘。
 *
 * 依赖方向：仅依赖底层 dto/ApiDto.ets（服务器契约），不依赖应用模型或其它实体。
 * DTO → 本实体的转换函数在本文件内，谁定义模型谁负责转换。
 */
export interface ComicAlbum {
  // ── 身份 ──
  id: number;
  seriesId: string;
  title: string;

  // ── 简介 ──
  description: string;
  /** 封面文件名（服务器原始字段，不存拼好的 URL） */
  imageName: string;
  /** 收录时间（Unix 时间戳字符串，服务器 addtime） */
  addTime: string;

  // ── 作者与分类（规范化但不丢信息）──
  authors: string[];
  category: ComicCategory;
  /** 子分类（服务器 category_sub） */
  subCategory: ComicCategory;
  tags: string[];
  works: string[];
  actors: string[];

  // ── 内容属性 ──
  /** 成人内容标识（服务器 is_aids） */
  isAids: boolean;
  /** 价格（通常为空字符串） */
  price: string;

  // ── 章节目录（只有目录项，不含图片；内容按章独立存储）──
  chapters: ComicChapter[];

  // ── 本地元数据 ──
  /** 本实体最后一次从服务器刷新的时间 */
  updatedAt: number;
}

export interface ComicCategory {
  id: number;
  title: string;
}

/** 可单独覆盖/清除的漫画字段名 */
export type ComicAlbumField =
  | 'seriesId' | 'title' | 'description' | 'imageName' | 'addTime'
  | 'authors' | 'category' | 'subCategory' | 'tags' | 'works' | 'actors'
  | 'isAids' | 'price' | 'chapters';

/**
 * 漫画部分更新：只覆盖出现的字段，未出现的保持原值。
 * 列表接口只返回摘要时用 albumPatchFromList()，详情接口用 albumPatchFromDetail()，
 * 从而做到「首页只更新封面标题，详情页才更新全量」。
 */
export interface ComicAlbumPatch {
  seriesId?: string;
  title?: string;
  description?: string;
  imageName?: string;
  addTime?: string;
  authors?: string[];
  category?: ComicCategory;
  subCategory?: ComicCategory;
  tags?: string[];
  works?: string[];
  actors?: string[];
  isAids?: boolean;
  price?: string;
  chapters?: ComicChapter[];
}

/** 服务器下发的单张图片原始引用（保真，不丢 URL） */
export interface ChapterImageRef {
  imgName: string;
  imgUrl: string;
  downloadUrl: string;
}

/**
 * 章节目录项：只描述「有哪些章节、怎么排序」。
 * 图片与解码参数不在这里，避免 album.json 随阅读进度膨胀。
 */
export interface ComicChapter {
  /** 章节 ID（series[].id 数值化） */
  id: number;
  /** 章节图片接口用的 photoId（series[].id 字符串形态） */
  photoId: string;
  title: string;
  sort: number;
}

/**
 * 章节内容：/chapter 响应中属于「内容」的完整数据，独立成一章一个文件
 * （albums/{albumId}/chapter-data/{photoId}.json）。
 */
export interface ChapterContent {
  id: number;
  photoId: string;
  title: string;
  scrambleId: number;
  images: ChapterImageRef[];
  updatedAt: number;
}

/** 可单独覆盖/清除的章节内容字段名 */
export type ChapterContentField = 'id' | 'title' | 'scrambleId' | 'images';

/** 章节内容部分更新：只覆盖出现的字段 */
export interface ChapterContentPatch {
  id?: number;
  title?: string;
  scrambleId?: number;
  images?: ChapterImageRef[];
}

/** 落盘文件结构（仅包一层版本号，便于将来演进） */
interface ComicAlbumFile {
  version: number;
  album: ComicAlbum;
}

interface ChapterContentFile {
  version: number;
  content: ChapterContent;
}

/**
 * 漫画实体仓库：内存 Map + filesDir 持久化
 *
 * 目录结构：
 *   albums/{albumId}/album.json                 → 漫画目录（基本信息 + 章节列表，体积小）
 *   albums/{albumId}/chapter-data/{photoId}.json→ 单章内容（图片引用 + 解码参数）
 */
export class ComicAlbumStore {
  private static instance: ComicAlbumStore | null = null;
  private static readonly VERSION: number = 1;
  private static staticBaseDir: string = '';
  private baseDir: string = '';
  private cache: Map<number, ComicAlbum> = new Map<number, ComicAlbum>();
  /** 章节内容内存副本，key = `${albumId}/${photoId}` */
  private contentCache: Map<string, ChapterContent> = new Map<string, ChapterContent>();

  private constructor() {
  }

  static async getInstance(): Promise<ComicAlbumStore> {
    if (ComicAlbumStore.instance === null) {
      let store = new ComicAlbumStore();
      await store.init();
      ComicAlbumStore.instance = store;
    }
    return ComicAlbumStore.instance;
  }

  private async init(): Promise<void> {
    let ctx = getContext() as common.UIAbilityContext;
    this.baseDir = `${ctx.filesDir}/JMComic/albums`;
    ComicAlbumStore.staticBaseDir = this.baseDir;
    if (!fileIo.accessSync(this.baseDir)) {
      fileIo.mkdirSync(this.baseDir, true);
    }
  }

  /** 一部漫画的根目录（实体、章节内容、章节 PNG 都在此下） */
  static albumRoot(albumId: number): string {
    return `${ComicAlbumStore.staticBaseDir}/${albumId}`;
  }

  private getFilePath(albumId: number): string {
    return `${ComicAlbumStore.albumRoot(albumId)}/album.json`;
  }

  private getChapterDataDir(albumId: number): string {
    return `${ComicAlbumStore.albumRoot(albumId)}/chapter-data`;
  }

  private getContentPath(albumId: number, photoId: string): string {
    let safe = photoId.replace(/[\/\\:*?"<>|]/g, '_').trim();
    return `${this.getChapterDataDir(albumId)}/${safe}.json`;
  }

  // ─── 目录读写 ───

  /** 读取：内存 → 文件，均未命中返回 null */
  get(albumId: number): ComicAlbum | null {
    let cached = this.cache.get(albumId);
    if (cached) return cached;
    try {
      let path = this.getFilePath(albumId);
      if (!fileIo.accessSync(path)) return null;
      let file = JSON.parse(fileIo.readTextSync(path)) as ComicAlbumFile;
      if (!file || file.version !== ComicAlbumStore.VERSION || !file.album) return null;
      this.cache.set(albumId, file.album);
      return file.album;
    } catch (e) {
      console.warn(`[ComicAlbumStore] read failed ${albumId}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /** 落盘 + 回填内存（自动创建专辑目录） */
  save(album: ComicAlbum): void {
    try {
      let root = ComicAlbumStore.albumRoot(album.id);
      if (!fileIo.accessSync(root)) fileIo.mkdirSync(root, true);
      let file: ComicAlbumFile = {
        version: ComicAlbumStore.VERSION,
        album: album,
      } as ComicAlbumFile;
      let f = fileIo.openSync(this.getFilePath(album.id),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(file));
      fileIo.closeSync(f);
      this.cache.set(album.id, album);
    } catch (e) {
      console.warn(`[ComicAlbumStore] save failed ${album.id}: ${JSON.stringify(e)}`);
    }
  }

  /** 空实体骨架（部分更新时按需创建） */
  private static emptyAlbum(albumId: number): ComicAlbum {
    return {
      id: albumId,
      seriesId: '',
      title: '',
      description: '',
      imageName: '',
      addTime: '',
      authors: [],
      category: { id: 0, title: '' } as ComicCategory,
      subCategory: { id: 0, title: '' } as ComicCategory,
      tags: [],
      works: [],
      actors: [],
      isAids: false,
      price: '',
      chapters: [],
      updatedAt: Date.now(),
    } as ComicAlbum;
  }

  /**
   * 部分更新：只覆盖 patch 中出现的字段，其余保持原值。
   * 实体不存在时按空骨架创建，因此「首页只拿到封面标题」也能先落一份摘要。
   * @returns 是否成功写入
   */
  updateAlbum(albumId: number, patch: ComicAlbumPatch): boolean {
    let album = this.get(albumId) ?? ComicAlbumStore.emptyAlbum(albumId);
    ComicAlbumStore.applyPatch(album, patch);
    album.updatedAt = Date.now();
    this.save(album);
    return true;
  }

  /**
   * 清除指定字段：字符串清空、数组清空、布尔置 false、章节清空。
   * 只清字段，不删除实体本身。
   * @returns 实体是否存在
   */
  clearAlbumFields(albumId: number, fields: ComicAlbumField[]): boolean {
    let album = this.get(albumId);
    if (!album) return false;
    let set = new Set<string>(fields);
    if (set.has('seriesId')) album.seriesId = '';
    if (set.has('title')) album.title = '';
    if (set.has('description')) album.description = '';
    if (set.has('imageName')) album.imageName = '';
    if (set.has('addTime')) album.addTime = '';
    if (set.has('authors')) album.authors = [];
    if (set.has('category')) album.category = { id: 0, title: '' } as ComicCategory;
    if (set.has('subCategory')) album.subCategory = { id: 0, title: '' } as ComicCategory;
    if (set.has('tags')) album.tags = [];
    if (set.has('works')) album.works = [];
    if (set.has('actors')) album.actors = [];
    if (set.has('isAids')) album.isAids = false;
    if (set.has('price')) album.price = '';
    if (set.has('chapters')) album.chapters = [];
    album.updatedAt = Date.now();
    this.save(album);
    return true;
  }

  /**
   * 章节内容部分更新：只覆盖出现的字段。
   * 内容文件不存在时按空骨架创建，便于「只更新 scrambleId」这类场景。
   */
  updateChapterContentFields(albumId: number, photoId: string,
    patch: ChapterContentPatch): boolean {
    let existing = this.getChapterContent(albumId, photoId);
    let content: ChapterContent = existing ?? {
      id: 0,
      photoId: photoId,
      title: '',
      scrambleId: 0,
      images: [],
      updatedAt: Date.now(),
    } as ChapterContent;
    if (patch.id !== undefined) content.id = patch.id;
    if (patch.title !== undefined) content.title = patch.title;
    if (patch.scrambleId !== undefined) content.scrambleId = patch.scrambleId;
    if (patch.images !== undefined) content.images = patch.images;
    this.saveChapterContent(albumId, content);
    return true;
  }

  /** 清除章节内容的指定字段（不删除内容文件本身） */
  clearChapterContentFields(albumId: number, photoId: string,
    fields: ChapterContentField[]): boolean {
    let content = this.getChapterContent(albumId, photoId);
    if (!content) return false;
    let set = new Set<string>(fields);
    if (set.has('id')) content.id = 0;
    if (set.has('title')) content.title = '';
    if (set.has('scrambleId')) content.scrambleId = 0;
    if (set.has('images')) content.images = [];
    this.saveChapterContent(albumId, content);
    return true;
  }

  /** 枚举磁盘上已有的漫画 ID（供清理、统计、批量操作使用） */
  getAllAlbumIds(): number[] {
    let ids: number[] = [];
    try {
      if (!fileIo.accessSync(this.baseDir)) return ids;
      let names = fileIo.listFileSync(this.baseDir);
      for (let name of names) {
        let id = parseInt(name);
        if (!isNaN(id) && id > 0) ids.push(id);
      }
    } catch (e) {
      console.warn(`[ComicAlbumStore] list albums failed: ${JSON.stringify(e)}`);
    }
    return ids;
  }

  /** 清空全部漫画（目录 + 章节内容 + 章节 PNG），返回清除的漫画数 */
  clearAll(): number {
    let ids = this.getAllAlbumIds();
    for (let id of ids) {
      this.remove(id);
    }
    this.cache.clear();
    this.contentCache.clear();
    console.info(`[ComicAlbumStore] cleared ${ids.length} albums`);
    return ids.length;
  }

  /** 删除整部漫画目录（目录 + 章节内容 + 章节 PNG + 生命周期清单），一次清干净 */
  remove(albumId: number): void {
    this.cache.delete(albumId);
    let prefix = `${albumId}/`;
    let keys: string[] = [];
    this.contentCache.forEach((_v: ChapterContent, key: string) => {
      if (key.startsWith(prefix)) keys.push(key);
    });
    for (let key of keys) {
      this.contentCache.delete(key);
    }
    try {
      let root = ComicAlbumStore.albumRoot(albumId);
      if (fileIo.accessSync(root)) fileIo.rmdirSync(root);
    } catch (e) {
      console.warn(`[ComicAlbumStore] remove failed ${albumId}: ${JSON.stringify(e)}`);
    }
  }

  // ─── 章节内容读写 ───

  /** 该章是否已缓存内容文件 */
  hasChapterContent(albumId: number, photoId: string): boolean {
    if (this.contentCache.has(`${albumId}/${photoId}`)) return true;
    return fileIo.accessSync(this.getContentPath(albumId, photoId));
  }

  /** 读取某章内容：内存 → 文件，未命中返回 null */
  getChapterContent(albumId: number, photoId: string): ChapterContent | null {
    let key = `${albumId}/${photoId}`;
    let cached = this.contentCache.get(key);
    if (cached) return cached;
    try {
      let path = this.getContentPath(albumId, photoId);
      if (!fileIo.accessSync(path)) return null;
      let file = JSON.parse(fileIo.readTextSync(path)) as ChapterContentFile;
      if (!file || file.version !== ComicAlbumStore.VERSION || !file.content) return null;
      this.contentCache.set(key, file.content);
      return file.content;
    } catch (e) {
      console.warn(`[ComicAlbumStore] read chapter content failed ${photoId}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /**
   * 保存某章内容（独立文件），并确保目录里有对应章节项。
   * 章节目录缺失时自动补入（服务器新增章节 / series 滞后）。
   */
  saveChapterContent(albumId: number, content: ChapterContent): void {
    let payload: ChapterContent = {
      id: content.id,
      photoId: content.photoId,
      title: content.title,
      scrambleId: content.scrambleId,
      images: content.images,
      updatedAt: Date.now(),
    } as ChapterContent;
    try {
      let dir = this.getChapterDataDir(albumId);
      if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir, true);
      let file: ChapterContentFile = {
        version: ComicAlbumStore.VERSION,
        content: payload,
      } as ChapterContentFile;
      let f = fileIo.openSync(this.getContentPath(albumId, payload.photoId),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(file));
      fileIo.closeSync(f);
      this.contentCache.set(`${albumId}/${payload.photoId}`, payload);
    } catch (e) {
      console.warn(`[ComicAlbumStore] save chapter content failed ${content.photoId}: ${JSON.stringify(e)}`);
      return;
    }
    this.ensureChapterEntry(albumId, payload);
  }

  /** 用章节内容回填目录（同 saveChapterContent，语义化别名） */
  updateChapterContent(albumId: number, content: ChapterContent): void {
    this.saveChapterContent(albumId, content);
  }

  /**
   * 删除某章的内容文件（保留章节目录项）。
   * 用于服务端换版后清理旧引用，或按需释放单章数据。
   */
  removeChapterContent(albumId: number, photoId: string): void {
    this.contentCache.delete(`${albumId}/${photoId}`);
    try {
      let path = this.getContentPath(albumId, photoId);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      console.warn(`[ComicAlbumStore] remove chapter content failed ${photoId}: ${JSON.stringify(e)}`);
    }
  }

  /** 清空某部漫画的全部章节内容文件（保留目录与基本信息） */
  clearChapterContents(albumId: number): number {
    let album = this.get(albumId);
    if (!album) return 0;
    let count = 0;
    for (let ch of album.chapters) {
      if (this.hasChapterContent(albumId, ch.photoId)) {
        this.removeChapterContent(albumId, ch.photoId);
        count++;
      }
    }
    return count;
  }

  /** 确保目录里有该章；标题/ID 以服务器最新值为准 */
  private ensureChapterEntry(albumId: number, content: ChapterContent): void {
    let album = this.get(albumId);
    if (!album) return;

    let existing: ComicChapter | null = null;
    for (let ch of album.chapters) {
      if (ch.photoId === content.photoId) {
        existing = ch;
        break;
      }
    }

    if (!existing) {
      // series 未包含该章（服务器新增 / 目录滞后）：按当前末尾顺序补入
      album.chapters.push({
        id: content.id,
        photoId: content.photoId,
        title: content.title || `第${content.photoId}话`,
        sort: album.chapters.length + 1,
      } as ComicChapter);
      album.chapters.sort((a: ComicChapter, b: ComicChapter) => a.sort - b.sort);
      this.save(album);
      return;
    }

    let changed = false;
    if (content.id > 0 && existing.id !== content.id) {
      existing.id = content.id;
      changed = true;
    }
    if (content.title.length > 0 && existing.title !== content.title) {
      existing.title = content.title;
      changed = true;
    }
    if (changed) this.save(album);
  }

  // ─── DTO → 实体 / 部分更新 ───

  /**
   * 列表 DTO → 摘要 patch：只含列表页真正拿得到的字段。
   * 首页/搜索/收藏只更新标题、封面、作者、简介、分类，不碰章节与详情字段。
   */
  static albumPatchFromList(info: RespJmAlbumInfo): ComicAlbumPatch {
    let authors: string[] = [];
    if (typeof info.author === 'string') {
      if (info.author.length > 0) authors.push(info.author);
    } else if (info.author) {
      for (let a of info.author) {
        if (a && a.length > 0) authors.push(a);
      }
    }
    let category: ComicCategory = {
      id: (info.category && typeof info.category !== 'string') ? info.category.id : 0,
      title: typeof info.category === 'string' ? info.category
        : (info.category ? info.category.title : ''),
    } as ComicCategory;
    return {
      title: info.name || '',
      description: info.description || '',
      imageName: info.image || '',
      authors: authors,
      category: category,
      addTime: info.addtime || '',
    } as ComicAlbumPatch;
  }

  /** 详情 DTO → 全量 patch（含章节目录、分类、标签、价格等） */
  static albumPatchFromDetail(dto: JmAlbumDetail): ComicAlbumPatch {
    let authors: string[] = [];
    if (typeof dto.author === 'string') {
      if (dto.author.length > 0) authors.push(dto.author);
    } else if (dto.author) {
      for (let a of dto.author) {
        if (a && a.length > 0) authors.push(a);
      }
    }
    let category: ComicCategory = {
      id: dto.category ? dto.category.id : 0,
      title: dto.category ? dto.category.title : '',
    } as ComicCategory;
    let subCategory: ComicCategory = {
      id: dto.category_sub ? dto.category_sub.id : 0,
      title: dto.category_sub ? dto.category_sub.title : '',
    } as ComicCategory;

    let chapters: ComicChapter[] = [];
    if (dto.series && dto.series.length > 0) {
      for (let i = 0; i < dto.series.length; i++) {
        chapters.push(ComicAlbumStore.chapterFromSeries(dto.series[i], i));
      }
    } else {
      chapters.push({
        id: dto.id, photoId: String(dto.id), title: '第1话', sort: 1,
      } as ComicChapter);
    }

    return {
      seriesId: dto.series_id || '',
      title: dto.name || '',
      description: dto.description || '',
      imageName: dto.image || '',
      addTime: dto.addtime || '',
      authors: authors,
      category: category,
      subCategory: subCategory,
      tags: dto.tags || [],
      works: dto.works || [],
      actors: dto.actors || [],
      isAids: dto.is_aids === true,
      price: dto.price || '',
      chapters: chapters,
    } as ComicAlbumPatch;
  }

  /** 详情 DTO → 完整实体（纯转换，章节目录只有目录字段） */
  static fromDetail(dto: JmAlbumDetail): ComicAlbum {
    let album = ComicAlbumStore.emptyAlbum(dto.id);
    ComicAlbumStore.applyPatch(album, ComicAlbumStore.albumPatchFromDetail(dto));
    album.updatedAt = Date.now();
    return album;
  }

  /** 把 patch 中的字段应用到实体（供 updateAlbum / fromDetail 共用） */
  private static applyPatch(album: ComicAlbum, patch: ComicAlbumPatch): void {
    if (patch.seriesId !== undefined) album.seriesId = patch.seriesId;
    if (patch.title !== undefined) album.title = patch.title;
    if (patch.description !== undefined) album.description = patch.description;
    if (patch.imageName !== undefined) album.imageName = patch.imageName;
    if (patch.addTime !== undefined) album.addTime = patch.addTime;
    if (patch.authors !== undefined) album.authors = patch.authors;
    if (patch.category !== undefined) album.category = patch.category;
    if (patch.subCategory !== undefined) album.subCategory = patch.subCategory;
    if (patch.tags !== undefined) album.tags = patch.tags;
    if (patch.works !== undefined) album.works = patch.works;
    if (patch.actors !== undefined) album.actors = patch.actors;
    if (patch.isAids !== undefined) album.isAids = patch.isAids;
    if (patch.price !== undefined) album.price = patch.price;
    if (patch.chapters !== undefined) album.chapters = patch.chapters;
  }

  /**
   * 列表项 → 只更新摘要字段（标题/封面/作者/简介/分类），不动章节与详情字段。
   * 首页、搜索、收藏等列表页用它，避免用「只有摘要」的数据覆盖掉详情。
   */
  static async saveFromList(info: RespJmAlbumInfo): Promise<ComicAlbum | null> {
    let albumId = Number(info.id) || 0;
    if (albumId <= 0) return null;
    let store = await ComicAlbumStore.getInstance();
    store.updateAlbum(albumId, ComicAlbumStore.albumPatchFromList(info));
    return store.get(albumId);
  }

  /**
   * 详情 DTO → 部分更新（只覆盖详情接口真正返回的字段）。
   * 刷新时保留「服务器目录里没有、但本地已有内容文件」的章节——
   * 这类章节通常是 series 滞后或服务器后来新增的，丢弃会导致已读章节凭空消失。
   */
  static async saveFromDetail(dto: JmAlbumDetail): Promise<ComicAlbum | null> {
    let store = await ComicAlbumStore.getInstance();
    let patch = ComicAlbumStore.albumPatchFromDetail(dto);
    let old = store.get(dto.id);
    if (old && patch.chapters) {
      let freshIds = new Set<string>();
      for (let ch of patch.chapters) {
        freshIds.add(ch.photoId);
      }
      for (let ch of old.chapters) {
        if (!freshIds.has(ch.photoId) && store.hasChapterContent(dto.id, ch.photoId)) {
          patch.chapters.push(ch);
        }
      }
      patch.chapters.sort((a: ComicChapter, b: ComicChapter) => a.sort - b.sort);
    }
    store.updateAlbum(dto.id, patch);
    return store.get(dto.id);
  }

  private static chapterFromSeries(ep: JmAlbumSeries, index: number): ComicChapter {
    let sort = typeof ep.sort === 'number' ? ep.sort : parseInt(ep.sort) || (index + 1);
    return {
      id: typeof ep.id === 'number' ? ep.id : parseInt(ep.id) || 0,
      photoId: ep.id !== undefined && ep.id !== null ? String(ep.id) : '',
      title: ep.name || '',
      sort: sort,
    } as ComicChapter;
  }

  /**
   * /chapter 响应 → 章节内容（服务器原始字段全保留）
   * 含真实章节名、数值 ID、解码参数、图片文件名与两个原始 URL。
   */
  static chapterContentOf(resp: JmPictureResp): ChapterContent {
    let images: ChapterImageRef[] = [];
    for (let img of resp.images) {
      images.push({
        imgName: img.img_name,
        imgUrl: img.img_url,
        downloadUrl: img.download_url,
      } as ChapterImageRef);
    }
    return {
      id: resp.id || 0,
      photoId: String(resp.photo_id || resp.id),
      title: resp.name || '',
      scrambleId: resp.scramble_id || 0,
      images: images,
      updatedAt: Date.now(),
    } as ChapterContent;
  }

  // ─── 派生显示字段（不落盘，只依赖实体自身）──

  /** 作者显示文本：用「、」连接 */
  static authorText(album: ComicAlbum): string {
    return album.authors.join('、');
  }

  /** 分类显示文本 */
  static categoryText(album: ComicAlbum): string {
    return album.category.title;
  }

  /** 章节数 */
  static chapterCount(album: ComicAlbum): number {
    return album.chapters.length;
  }

  /**
   * 总图片数：累加各章已缓存内容里的图片数。
   * /album 不返回总页数，只有拉过章节内容后才准确，故不落盘。
   */
  totalPictures(albumId: number): number {
    let album = this.get(albumId);
    if (!album) return 0;
    let total = 0;
    for (let ch of album.chapters) {
      let content = this.getChapterContent(albumId, ch.photoId);
      total += content && content.images ? content.images.length : 0;
    }
    return total;
  }
}
