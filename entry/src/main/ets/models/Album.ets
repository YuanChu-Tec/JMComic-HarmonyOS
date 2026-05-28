/**
 * 漫画数据模型定义
 * 对应 Python 项目中的 JmAlbumDetail, JmPhotoDetail, JmImageDetail
 */

// ── JSON 序列化接口 ──

export interface IDownloadTaskJSON {
  taskId: string;
  albumId: number;
  albumName: string;
  chapterName: string;
  photoId: string;
  scrambleId: number;
  status: DownloadStatus;
  totalImages: number;
  completedImages: number;
  errorMsg: string;
  addTime: number;
}

export interface IAlbumViewModelJSON {
  id: string;
  name: string;
  author: string;
  coverUrl: string;
  description: string;
  totalViews: string;
  totalPicture: string;
  likes: string;
  category: string;
}

// ── 接口响应原始结构 ──

/** 搜索/列表返回的 Album 简要信息 */
/** 首页推荐分区 */
export interface JmPromoteSection {
  title: string;
  content: JmAlbumInfo[];
}

export interface JmAlbumInfo {
  id: number | string;     // API 返回字符串，需兼容
  name: string;            // 作品名
  author: string | string[];  // 作者（可能是字符串或数组）
  image: string;           // 封面图文件名
  description: string;     // 描述
  category: CategoryBean | string;
  // 以下字段仅在 album 详情 API 中返回，列表 API 中不存在
  total_views?: string;    // 总观看次数
  total_picture?: string;  // 总图片数
  likes?: string;          // 喜欢数
  addtime?: string;        // 添加时间 (时间戳)
  series?: JmAlbumSeries[];
}

export interface CategoryBean {
  id: number;
  title: string;
}

export interface JmAlbumSeries {
  id: number | string;
  name: string;
  sort: number | string;
}

/** Album 完整详情（API 返回结构） */
export interface JmAlbumDetail {
  id: number;
  name: string;
  author: string | string[];  // API 返回字符串数组
  description: string | null;
  category?: CategoryBean;
  total_views: string;
  likes: string;
  series: JmAlbumSeries[];   // 章节列表 [{id, name, sort}, ...]
  series_id: string;
  comment_total: string;
  tags: string[];             // API 返回字符串数组
  works: string[];            // 所属作品/IP（如"原神"、"崩坏3"），纯字符串数组
  actors?: string[];
  related_list?: JmRelatedWork[];
  liked?: boolean;
  is_favorite?: boolean;
  images?: string[];
}

export interface JmPhotoInfo {
  id: number;
  photo_id: string;
  name: string;          // 章节名称
  index: number;         // 序号
  scramble_id: number;   // 加密用 ID
  addtime: string;
  publish_time: string;
  sort: number;
}

export interface JmTagInfo {
  id: number;
  name: string;
}

export interface JmRelatedWork {
  id: number;
  name: string;
  image: string;
  author: string;
}

export interface JmActorInfo {
  id: number;
  name: string;
  image: string | null;
}

/** 图片详情 (一个章节中的单张图片) */
export interface JmImageInfo {
  img_name: string;       // 图片文件名
  img_url: string;        // 完整图片 URL
  download_url: string;   // 下载 URL
}

/** 图片获取响应 */
export interface JmPictureResp {
  id: number;
  photo_id: string;
  name: string;
  images: JmImageInfo[];
  scramble_id: number;
}

// ── API 响应封装 ──

/** 通用 API 响应 */
export interface JmApiResponse<T> {
  code: number;           // 200 = 成功
  message: string;
  data: T;
}

/** 搜索/列表响应 data 结构 */
export interface SearchResultData {
  content: JmAlbumInfo[];
  total: string;
}

/** Album 详情响应 data 结构 */
export interface AlbumDetailData {
  album: JmAlbumDetail;
}

/** 图片响应 data 结构 */
export interface PictureData {
  pictures: JmPictureResp;
}

// ── 收藏系统模型 ──

/** 收藏夹文件夹项 */
export interface FavoriteFolderItem {
  FID: string;       // 文件夹ID
  name: string;      // 文件夹名称
}

/** 收藏夹中的本子摘要（API返回的list项） */
export interface FavoriteAlbumItem {
  id: string;
  name: string;
  author: string | string[];   // API可能返回字符串或数组
  description: string;
  image: string;               // 封面图文件名
  category: CategoryBean;
  category_sub: CategoryBean;
}

/** 收藏夹分页API响应 data */
export interface FavoritePageData {
  list: FavoriteAlbumItem[];
  folder_list: FavoriteFolderItem[];
  total: number;                // 总数
  count?: number;               // 本页数量
}

/** 收藏切换/操作结果 */
export interface FavoriteActionResult {
  status: string;   // "ok" 表示成功
  msg: string;
}

/** 收藏夹操作类型 */
export enum FavoriteFolderType {
  ADD = 'add',
  EDIT = 'edit',
  MOVE = 'move',
  DELETE = 'del',
}

/** 收藏夹操作参数 */
export interface FavoriteFolderParams {
  type: FavoriteFolderType;
  folderId?: string;
  folderName?: string;
  albumId?: string;
}

// ── 登录/用户系统 ──

/** 登录API响应 data */
export interface JmUserData {
  uid: string;
  username: string;
  email: string;
  emailverified: string;
  photo: string;              // 头像文件名
  fname: string;
  gender: string;
  message: string;
  coin: number;
  album_favorites: number;
  s: string;                  // session token
  level_name: string;
  level: number;
  nextLevelExp: number;
  exp: string;
  expPercent: number;
  badges: string[];
  album_favorites_max: number;
}

/** 用户视图模型（含持久化字段） */
export class UserSession {
  uid: string = '';
  username: string = '';
  email: string = '';
  photo: string = '';
  coin: number = 0;
  level: number = 0;
  levelName: string = '';
  albumFavorites: number = 0;
  albumFavoritesMax: number = 0;
  sessionToken: string = '';  // 's' field - used as cookie/AVS
  isLoggedIn: boolean = false;

  /** 从API返回数据创建 */
  static fromApiData(data: JmUserData): UserSession {
    let session = new UserSession();
    session.uid = data.uid;
    session.username = data.username;
    session.email = data.email;
    session.photo = data.photo;
    session.coin = data.coin;
    session.level = data.level;
    session.levelName = data.level_name;
    session.albumFavorites = data.album_favorites;
    session.albumFavoritesMax = data.album_favorites_max;
    session.sessionToken = data.s;
    session.isLoggedIn = true;
    return session;
  }

  /** 退出登录 */
  logout(): void {
    this.isLoggedIn = false;
    this.uid = '';
    this.username = '';
    this.email = '';
    this.photo = '';
    this.coin = 0;
    this.level = 0;
    this.levelName = '';
    this.albumFavorites = 0;
    this.albumFavoritesMax = 0;
    this.sessionToken = '';
  }
}

// ── 评论系统模型 ──

/** 评论信息（对应 Python CommentInfo） */
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

/** 评论列表 API 响应 data */
export interface CommentPageData {
  list: CommentInfoRaw[];
  total: number;
}

/** 评论原始数据 (API返回结构) */
export interface CommentInfoRaw {
  CID: string;
  UID: string;
  username: string;
  content: string;
  likes: number;
  addtime: string;
  photo: string;
  name: string;            // 关联漫画名称
  AID: string;             // 关联漫画ID
  expinfo: CommentExpInfo;
  replys: CommentInfoRaw[];
}

/** 用户经验信息 */
export interface CommentExpInfo {
  level: string;
  level_name: string;
}

/** 发送评论 API 响应 data */
export interface SendCommentData {
  msg: string;
}

/** 评论模式 */
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

/**
 * 去除 HTML 标签，提取纯文本内容
 */
function stripHtmlTags(html: string): string {
  return html.replace(/<[^>]*>/g, '').trim();
}

/**
 * 解析评论原始数据为 CommentInfo
 * 对应 Python: ToolUtil.ParseBookComment()
 */
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
  // 头像处理：排除默认头像
  let photo = raw.photo || '';
  if (photo !== 'nopic-Male.gif' && photo !== 'nopic-Female.gif' && photo.length > 0) {
    info.headUrl = '/media/users/' + photo;
  }
  // 解析子评论
  if (raw.replys && raw.replys.length > 0) {
    info.subComments = raw.replys.map((r: CommentInfoRaw) => parseCommentRaw(r));
  }
  return info;
}

// ── 下载系统模型 ──

/** 下载状态枚举 */
export enum DownloadStatus {
  QUEUED = 'queued',
  DOWNLOADING = 'downloading',
  PAUSED = 'paused',
  DONE = 'done',
  ERROR = 'error',
}

/** 单个下载任务（一个章节） */
export class DownloadTask {
  taskId: string = '';             // 唯一ID (albumId_photoId)
  albumId: number = 0;
  albumName: string = '';
  chapterName: string = '';
  photoId: string = '';
  scrambleId: number = 0;
  status: DownloadStatus = DownloadStatus.QUEUED;
  totalImages: number = 0;
  completedImages: number = 0;
  currentImageName: string = '';
  errorMsg: string = '';
  /** 时间戳（添加时间） */
  addTime: number = 0;

  /** 进度百分比 */
  getProgress(): number {
    if (this.totalImages === 0) return 0;
    return Math.floor(this.completedImages / this.totalImages * 100);
  }

  /** 状态文本 */
  getStatusText(): string {
    switch (this.status) {
      case DownloadStatus.QUEUED: return '等待中';
      case DownloadStatus.DOWNLOADING: return '下载中';
      case DownloadStatus.PAUSED: return '已暂停';
      case DownloadStatus.DONE: return '已完成';
      case DownloadStatus.ERROR: return '失败';
    }
  }

  toJSON(): IDownloadTaskJSON {
    return {
      taskId: this.taskId,
      albumId: this.albumId,
      albumName: this.albumName,
      chapterName: this.chapterName,
      photoId: this.photoId,
      scrambleId: this.scrambleId,
      status: this.status,
      totalImages: this.totalImages,
      completedImages: this.completedImages,
      errorMsg: this.errorMsg,
      addTime: this.addTime,
    };
  }

  static fromJSON(obj: IDownloadTaskJSON): DownloadTask {
    let task = new DownloadTask();
    task.taskId = obj.taskId as string;
    task.albumId = obj.albumId as number;
    task.albumName = obj.albumName as string;
    task.chapterName = obj.chapterName as string;
    task.photoId = obj.photoId as string;
    task.scrambleId = obj.scrambleId as number;
    task.status = obj.status as DownloadStatus;
    task.totalImages = obj.totalImages as number;
    task.completedImages = obj.completedImages as number;
    task.errorMsg = obj.errorMsg as string;
    task.addTime = obj.addTime as number;
    return task;
  }
}

// ── 显示用的视图模型 ──

/** 专辑列表项视图模型 */
export class AlbumViewModel {
  id: number = 0;
  name: string = '';
  author: string = '';
  coverUrl: string = '';
  description: string = '';
  totalViews: string = '0';
  totalPicture: string = '0';
  likes: string = '0';
  category: string = '';

  static fromApiInfo(info: JmAlbumInfo, coverUrl: string): AlbumViewModel {
    let vm = new AlbumViewModel();
    vm.id = typeof info.id === 'number' ? info.id : parseInt(info.id as string) || 0;
    vm.name = info.name || '';
    vm.description = info.description || '';
    vm.totalViews = info.total_views || '0';
    vm.totalPicture = info.total_picture || '0';
    vm.likes = info.likes || '0';
    // author 可能是字符串或数组
    if (Array.isArray(info.author)) {
      vm.author = (info.author as string[]).join(', ');
    } else {
      vm.author = (info.author as string) || '';
    }
    vm.category = typeof info.category === 'string' ? info.category : info.category?.title || '';
    vm.coverUrl = coverUrl;
    return vm;
  }

  /** 序列化为可缓存对象 */
  toJSON(): IAlbumViewModelJSON {
    return {
      id: this.id.toString(),
      name: this.name,
      author: this.author,
      coverUrl: this.coverUrl,
      description: this.description,
      totalViews: this.totalViews,
      totalPicture: this.totalPicture,
      likes: this.likes,
      category: this.category,
    };
  }

  /** 从缓存对象反序列化 */
  static fromJSON(obj: IAlbumViewModelJSON): AlbumViewModel {
    let vm = new AlbumViewModel();
    vm.id = parseInt(obj.id) || 0;
    vm.name = obj.name || '';
    vm.author = obj.author || '';
    vm.coverUrl = obj.coverUrl || '';
    vm.description = obj.description || '';
    vm.totalViews = obj.totalViews || '0';
    vm.totalPicture = obj.totalPicture || '0';
    vm.likes = obj.likes || '0';
    vm.category = obj.category || '';
    return vm;
  }

  /** 批量从 JSON 数组反序列化 */
  static fromJSONArray(arr: IAlbumViewModelJSON[]): AlbumViewModel[] {
    return arr.map(item => AlbumViewModel.fromJSON(item));
  }
}

/** 章节视图模型 */
export class PhotoViewModel {
  id: number = 0;
  photoId: string = '';
  name: string = '';
  index: number = 0;
  scrambleId: number = 0;

  static fromApiInfo(info: JmPhotoInfo): PhotoViewModel {
    let vm = new PhotoViewModel();
    vm.id = info.id;
    vm.photoId = info.photo_id;
    vm.name = info.name;
    vm.index = info.index;
    vm.scrambleId = info.scramble_id;
    return vm;
  }
}

/** 图片视图模型 */
export class ImageViewModel {
  imgName: string = '';
  imgUrl: string = '';
  downloadUrl: string = '';

  static fromApiInfo(info: JmImageInfo): ImageViewModel {
    let vm = new ImageViewModel();
    vm.imgName = info.img_name;
    vm.imgUrl = info.img_url;
    vm.downloadUrl = info.download_url;
    return vm;
  }
}
