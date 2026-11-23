import {
  CategoryBean, CommentInfoRaw, JmAlbumDetail, JmAlbumSeries, JmRelatedWork, RespJmAlbumInfo
} from './dto/ApiDto';

/**
 * 一部漫画的完整数据模型（纯类型 + 纯函数，无 IO）
 *
 * 按服务器接口分块，每块只存一份：
 * - album:     /album    → album 表                      → ComicAlbum
 * - chapters:  /album    的 series → chapter 表（目录）
 * - 章节图片:  /chapter  → ComicLibrary 的 meta.json（与 PNG 同目录，不落库）
 * - comments:  /comments → 分页快照，未入实体表
 *
 * 统计列的 NULL 语义由 DAO 维护：fetchedAt === 0 表示从未拉取，落库时写 NULL。
 *
 * 本文件只有 interface / enum / 常量与「DTO → 实体」的纯函数：
 * 不 import 数据库、不 import 文件系统。落库逻辑在 storage/AlbumDao。
 *
 * 原始字段保真：author 用数组、category 用原始结构、封面用文件名；
 * 显示字段（authorText/categoryText/chapterCount）由派生函数计算，不落盘。
 *
 * 依赖方向：仅依赖底层 dto/ApiDto.ets（服务器契约）。
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

  // ── 统计（只取服务器给的值，不等同于本地已缓存内容）──
  /**
   * 图片总数（服务器 total_picture，全本所有章节的图片张数）。
   * 只有列表接口返回，/album 详情接口不返回，因此仅由列表刷新更新。
   */
  totalPicture: string;

  // ── 实时统计与用户态（服务器下发，会变；'' / 0 表示从未拉取）──
  /** 总观看数（服务器字符串） */
  totalViews: string;
  /** 喜欢数（服务器字符串） */
  likes: string;
  /** 评论总数（服务器数值） */
  commentTotal: number;
  /** 当前用户是否已点赞 */
  liked: boolean;
  /** 当前用户是否已收藏 */
  isFavorite: boolean;
  /** 是否已购买（通常为空字符串） */
  purchased: string;
  /** 关联推荐（服务器下发，会变） */
  related: ComicRelatedRef[];

  // ── 拉取游标 ──
  /** 统计与关联推荐最后一次拉取时间，0 表示从未拉取 */
  fetchedAt: number;
  /** 已加载到的评论页码，0 表示尚未拉取 */
  commentPage: number;
  /** 评论最后一次拉取时间 */
  commentFetchedAt: number;

  // ── 本地元数据 ──
  /** 本实体最后一次从服务器刷新的时间 */
  updatedAt: number;
}

/** 关联作品摘要（对应服务器 related_list 的每一项，只取展示所需字段） */
export interface ComicRelatedRef {
  id: number;
  name: string;
  image: string;
  author: string;
  description: string;
  category: ComicCategory;
  subCategory: ComicCategory;
}

export interface ComicCategory {
  id: number;
  title: string;
}

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
  totalPicture?: string;
  totalViews?: string;
  likes?: string;
  commentTotal?: number;
  liked?: boolean;
  isFavorite?: boolean;
  purchased?: string;
  related?: ComicRelatedRef[];
  fetchedAt?: number;
  commentPage?: number;
  commentFetchedAt?: number;
}

/**
 * 章节目录项：只描述「有哪些章节、怎么排序」。
 * 图片与解码参数不在这里，避免目录随阅读进度膨胀。
 */
export interface ComicChapter {
  /** 章节 ID（series[].id 数值化） */
  id: number;
  /** 章节图片接口用的 photoId（series[].id 字符串形态） */
  photoId: string;
  title: string;
  sort: number;
}

// ─── 纯数据操作（无副作用、无 IO）───

/** 空实体骨架 */
export function emptyAlbum(albumId: number): ComicAlbum {
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
    totalPicture: '',
    totalViews: '',
    likes: '',
    commentTotal: 0,
    liked: false,
    isFavorite: false,
    purchased: '',
    related: [],
    fetchedAt: 0,
    commentPage: 0,
    commentFetchedAt: 0,
    updatedAt: Date.now(),
  } as ComicAlbum;
}

/** 把 patch 中的字段应用到实体（未出现的字段保持原值） */
export function applyAlbumPatch(album: ComicAlbum, patch: ComicAlbumPatch): void {
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
  if (patch.totalPicture !== undefined) album.totalPicture = patch.totalPicture;
  if (patch.totalViews !== undefined) album.totalViews = patch.totalViews;
  if (patch.likes !== undefined) album.likes = patch.likes;
  if (patch.commentTotal !== undefined) album.commentTotal = patch.commentTotal;
  if (patch.liked !== undefined) album.liked = patch.liked;
  if (patch.isFavorite !== undefined) album.isFavorite = patch.isFavorite;
  if (patch.purchased !== undefined) album.purchased = patch.purchased;
  if (patch.related !== undefined) album.related = patch.related;
  if (patch.fetchedAt !== undefined) album.fetchedAt = patch.fetchedAt;
  if (patch.commentPage !== undefined) album.commentPage = patch.commentPage;
  if (patch.commentFetchedAt !== undefined) album.commentFetchedAt = patch.commentFetchedAt;
}

/**
 * 列表 DTO → 摘要 patch：只含列表页真正拿得到的字段。
 * 更新标题、封面、作者、简介、分类、图片总数，不碰章节与详情字段。
 */
export function albumPatchFromList(info: RespJmAlbumInfo): ComicAlbumPatch {
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
  let patch: ComicAlbumPatch = {
    title: info.name || '',
    description: info.description || '',
    imageName: info.image || '',
    authors: authors,
    category: category,
    addTime: info.addtime || '',
    totalPicture: info.total_picture || '',
  } as ComicAlbumPatch;
  // 列表接口也带 views/likes；字段缺失时保持原值，避免用空串覆盖详情拉到的统计
  if (info.total_views !== undefined) {
    patch.totalViews = info.total_views;
    patch.fetchedAt = Date.now();
  }
  if (info.likes !== undefined) {
    patch.likes = info.likes;
    patch.fetchedAt = Date.now();
  }
  return patch;
}

/** 详情 DTO → 全量 patch（含章节目录、分类、标签、价格等） */
export function albumPatchFromDetail(dto: JmAlbumDetail): ComicAlbumPatch {
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
      chapters.push(chapterFromSeries(dto.series[i], i));
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
    totalViews: dto.total_views || '',
    likes: dto.likes || '',
    commentTotal: dto.comment_total || 0,
    liked: dto.liked === true,
    isFavorite: dto.is_favorite === true,
    purchased: dto.purchased || '',
    related: relatedFromList(dto.related_list),
    fetchedAt: Date.now(),
  } as ComicAlbumPatch;
}

/**
 * 实体 → 详情 DTO：读库后还原详情页的渲染数据（与 albumPatchFromDetail 对称）。
 * 章节由 chapters 还原成 series，收藏态取库里的值。
 */
export function detailFromAlbum(album: ComicAlbum): JmAlbumDetail {
  let series: JmAlbumSeries[] = [];
  for (let chapter of album.chapters) {
    series.push({ id: chapter.photoId, name: chapter.title, sort: chapter.sort } as JmAlbumSeries);
  }
  let category: CategoryBean = {
    id: album.category.id,
    title: album.category.title,
  };
  let subCategory: CategoryBean = {
    id: album.subCategory.id,
    title: album.subCategory.title,
  };
  // 关联推荐同样从库里还原：详情页「相关作品」直接读 related_list
  let relatedList: JmRelatedWork[] = [];
  for (let r of album.related) {
    relatedList.push({
      id: r.id,
      name: r.name,
      image: r.image,
      author: r.author,
      description: r.description,
      category: { id: r.category.id, title: r.category.title } as CategoryBean,
      category_sub: { id: r.subCategory.id, title: r.subCategory.title } as CategoryBean,
    } as JmRelatedWork);
  }
  let detail: JmAlbumDetail = {
    id: album.id,
    name: album.title,
    author: album.authors,
    description: album.description,
    addtime: album.addTime,
    category: category,
    category_sub: subCategory,
    total_views: album.totalViews,
    likes: album.likes,
    series: series,
    series_id: album.seriesId,
    comment_total: album.commentTotal,
    tags: album.tags,
    works: album.works,
    actors: album.actors,
    is_favorite: album.isFavorite,
    is_aids: album.isAids,
    price: album.price,
    purchased: album.purchased,
    image: album.imageName,
    related_list: relatedList,
  };
  return detail;
}

/**
 * 关联推荐 DTO → 摘要数组。
 * 返回 undefined 表示「本次响应没带 related_list」，调用方应保持原有值而不是清空。
 */
export function relatedFromList(list: JmRelatedWork[] | undefined): ComicRelatedRef[] | undefined {
  if (!list) return undefined;
  let related: ComicRelatedRef[] = [];
  for (let r of list) {
    related.push({
      id: r.id,
      name: r.name,
      image: r.image,
      author: r.author,
      description: r.description || '',
      category: {
        id: r.category ? r.category.id : 0,
        title: r.category ? r.category.title : '',
      } as ComicCategory,
      subCategory: {
        id: r.category_sub ? r.category_sub.id : 0,
        title: r.category_sub ? r.category_sub.title : '',
      } as ComicCategory,
    } as ComicRelatedRef);
  }
  return related;
}

/** 详情 DTO → 完整实体（纯转换，章节目录只有目录字段） */
export function albumFromDetail(dto: JmAlbumDetail): ComicAlbum {
  let album = emptyAlbum(dto.id);
  applyAlbumPatch(album, albumPatchFromDetail(dto));
  album.updatedAt = Date.now();
  return album;
}

function chapterFromSeries(ep: JmAlbumSeries, index: number): ComicChapter {
  let sort = typeof ep.sort === 'number' ? ep.sort : parseInt(ep.sort) || (index + 1);
  return {
    id: typeof ep.id === 'number' ? ep.id : parseInt(ep.id) || 0,
    photoId: ep.id !== undefined && ep.id !== null ? String(ep.id) : '',
    title: ep.name || '',
    sort: sort,
  } as ComicChapter;
}

// ─── 派生显示字段（不落盘，只依赖实体自身）───

/** 作者显示文本：用「、」连接 */
export function authorText(album: ComicAlbum): string {
  return album.authors.join('、');
}

/** 分类显示文本 */
export function categoryText(album: ComicAlbum): string {
  return album.category.title;
}

/** 章节数 */
export function chapterCount(album: ComicAlbum): number {
  return album.chapters.length;
}

// ─── 评论（comment 表 / /comments 响应）───

/**
 * 评论内容：/comments 响应解析后的实体，只存在于内存与 comment 表。
 * 社区流（不带 albumId）与漫画详情评论共用同一结构，
 * 落表时 album_id 用 0 表示「无归属」，详见 AppDatabase 的 comment 表。
 */
export interface CommentInfo {
  id: string;              // CID
  uid: string;             // UID
  name: string;            // username
  level: string;           // expinfo.level
  title: string;           // expinfo.level_name
  date: string;            // addtime
  content: string;         // 评论内容
  headUrl: string;         // 头像路径 (/media/users/xxx)
  like: number;            // likes
  linkBookId: string;      // AID 关联漫画
  linkBookName: string;    // 关联漫画名称
  subComments: CommentInfo[];  // 子评论列表
}

/** 评论模式（ApiService.getComments 使用） */
export const COMMENT_MODE_ALL: string = 'all';
export const COMMENT_MODE_MANHUA: string = 'manhua';
export const COMMENT_MODE_CHAT: string = 'chat';
export const COMMENT_MODE_MY: string = 'undefined';

/** 评论模式名称映射 */
export const COMMENT_MODE_NAME_MAP: Record<string, string> = {
  'all': '所有',
  'manhua': '漫画',
  'chat': '闲聊',
};

function stripHtmlTags(html: string): string {
  return html.replace(/<[^>]*>/g, '').trim();
}

/** 解析评论原始数据为 CommentInfo */
export function parseCommentRaw(raw: CommentInfoRaw): CommentInfo {
  let info: CommentInfo = {
    id: raw.CID || '',
    uid: raw.UID || '',
    name: raw.username || '',
    level: raw.expinfo?.level || '',
    title: raw.expinfo?.level_name || '',
    date: raw.addtime || '',
    content: stripHtmlTags(raw.content || ''),
    headUrl: '',
    like: raw.likes || 0,
    linkBookId: raw.AID || '',
    linkBookName: raw.name || '',
    subComments: [],
  };
  let photo = raw.photo || '';
  if (photo !== 'nopic-Male.gif' && photo !== 'nopic-Female.gif' && photo.length > 0) {
    info.headUrl = '/media/users/' + photo;
  }
  if (raw.replys && raw.replys.length > 0) {
    info.subComments = raw.replys.map((r: CommentInfoRaw) => parseCommentRaw(r));
  }
  return info;
}

// ─── 聚合视图（内存，不落盘）───

