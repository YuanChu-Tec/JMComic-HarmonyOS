import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { JmAlbumDetail, CommentInfoRaw } from './dto/ApiDto';

/**
 * 漫画实时数据（缓存层）
 *
 * 与 ComicAlbum（固有数据，filesDir）分离：
 * - 存于 cacheDir，设置页「清理缓存」/ 系统存储紧张时可随时丢弃
 * - 丢弃后不影响漫画本体；下次进入详情页重新从服务器拉取即可
 *
 * 内容：会随时间/用户变化的统计与状态字段。
 */
export interface ComicRealtime {
  albumId: number;
  /** 总观看数 */
  totalViews: string;
  /** 喜欢数 */
  likes: string;
  /** 评论总数 */
  commentTotal: number;
  /** 当前用户是否已点赞 */
  liked: boolean;
  /** 当前用户是否已收藏 */
  isFavorite: boolean;
  /** 是否已购买（通常为空字符串，服务器 purchased） */
  purchased: string;
  /** 关联推荐（服务器下发，会变） */
  related: ComicRelatedRef[];
  /** 从服务器拉取的时间 */
  fetchedAt: number;
}

/** 关联作品摘要（对应服务器 related_list 的每一项） */
export interface ComicRelatedRef {
  id: number;
  name: string;
  image: string;
  author: string;
  description: string;
  category: ComicCategoryRef;
  subCategory: ComicCategoryRef;
}

export interface ComicCategoryRef {
  id: number;
  title: string;
}

// ─── 评论实时内容 ───

/** 评论信息（解析后，会实时变化） */
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

interface RealtimeFile {
  version: number;
  data: ComicRealtime;
}

/**
 * 实时数据仓库：内存 Map + cacheDir 持久化（一部漫画一个 JSON 文件）
 */
export class ComicRealtimeStore {
  private static instance: ComicRealtimeStore | null = null;
  private static readonly VERSION: number = 1;
  private baseDir: string = '';
  private cache: Map<number, ComicRealtime> = new Map<number, ComicRealtime>();

  private constructor() {
  }

  static async getInstance(): Promise<ComicRealtimeStore> {
    if (ComicRealtimeStore.instance === null) {
      let store = new ComicRealtimeStore();
      await store.init();
      ComicRealtimeStore.instance = store;
    }
    return ComicRealtimeStore.instance;
  }

  private async init(): Promise<void> {
    let ctx = getContext() as common.UIAbilityContext;
    this.baseDir = `${ctx.cacheDir}/JMComic/albums`;
    if (!fileIo.accessSync(this.baseDir)) {
      fileIo.mkdirSync(this.baseDir, true);
    }
  }

  private getFilePath(albumId: number): string {
    return `${this.baseDir}/${albumId}.json`;
  }

  /** 读取：内存 → 文件，均未命中返回 null */
  get(albumId: number): ComicRealtime | null {
    let cached = this.cache.get(albumId);
    if (cached) return cached;
    try {
      let path = this.getFilePath(albumId);
      if (!fileIo.accessSync(path)) return null;
      let file = JSON.parse(fileIo.readTextSync(path)) as RealtimeFile;
      if (!file || file.version !== ComicRealtimeStore.VERSION || !file.data) return null;
      this.cache.set(albumId, file.data);
      return file.data;
    } catch (e) {
      console.warn(`[ComicRealtimeStore] read failed ${albumId}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  /** 落盘 + 回填内存 */
  save(data: ComicRealtime): void {
    try {
      let file: RealtimeFile = {
        version: ComicRealtimeStore.VERSION,
        data: data,
      } as RealtimeFile;
      let f = fileIo.openSync(this.getFilePath(data.albumId),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(file));
      fileIo.closeSync(f);
      this.cache.set(data.albumId, data);
    } catch (e) {
      console.warn(`[ComicRealtimeStore] save failed ${data.albumId}: ${JSON.stringify(e)}`);
    }
  }

  /** 删除某部漫画的实时缓存 */
  remove(albumId: number): void {
    this.cache.delete(albumId);
    try {
      let path = this.getFilePath(albumId);
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
    } catch (e) {
      console.warn(`[ComicRealtimeStore] remove failed ${albumId}: ${JSON.stringify(e)}`);
    }
  }

  /** 枚举磁盘上已有实时缓存的漫画 ID */
  getAllAlbumIds(): number[] {
    let ids: number[] = [];
    try {
      if (!fileIo.accessSync(this.baseDir)) return ids;
      let names = fileIo.listFileSync(this.baseDir);
      for (let name of names) {
        if (!name.endsWith('.json')) continue;
        let id = parseInt(name.replace(/\.json$/, ''));
        if (!isNaN(id) && id > 0) ids.push(id);
      }
    } catch (e) {
      console.warn(`[ComicRealtimeStore] list albums failed: ${JSON.stringify(e)}`);
    }
    return ids;
  }

  /** 清空全部实时缓存（文件 + 内存），返回清除的漫画数 */
  clearAll(): number {
    let ids = this.getAllAlbumIds();
    for (let id of ids) {
      this.remove(id);
    }
    this.cache.clear();
    console.info(`[ComicRealtimeStore] cleared ${ids.length} albums`);
    return ids.length;
  }

  /** 详情 DTO → 实时数据快照（统计/用户态/关联推荐） */
  static fromDetail(dto: JmAlbumDetail): ComicRealtime {
    let related: ComicRelatedRef[] = [];
    if (dto.related_list) {
      for (let r of dto.related_list) {
        related.push({
          id: r.id,
          name: r.name,
          image: r.image,
          author: r.author,
          description: r.description || '',
          category: {
            id: r.category ? r.category.id : 0,
            title: r.category ? r.category.title : '',
          } as ComicCategoryRef,
          subCategory: {
            id: r.category_sub ? r.category_sub.id : 0,
            title: r.category_sub ? r.category_sub.title : '',
          } as ComicCategoryRef,
        } as ComicRelatedRef);
      }
    }
    return {
      albumId: dto.id,
      totalViews: dto.total_views || '0',
      likes: dto.likes || '0',
      commentTotal: dto.comment_total || 0,
      liked: dto.liked === true,
      isFavorite: dto.is_favorite === true,
      purchased: dto.purchased || '',
      related: related,
      fetchedAt: Date.now(),
    } as ComicRealtime;
  }

  /** 详情 DTO → 实时数据并落盘（cacheDir） */
  static async saveFromDetail(dto: JmAlbumDetail): Promise<ComicRealtime> {
    let store = await ComicRealtimeStore.getInstance();
    let data = ComicRealtimeStore.fromDetail(dto);
    store.save(data);
    return data;
  }

  /** cacheDir 被清空后，内存缓存也应失效（设置页清理缓存后调用） */
  invalidateAll(): void {
    this.cache.clear();
  }
}

// ─── 评论 DTO → 实时评论内容的转换 ───

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
