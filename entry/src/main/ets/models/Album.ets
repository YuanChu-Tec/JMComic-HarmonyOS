import { RespJmAlbumInfo, JmUserData, JmAlbumSeries, JmPhotoInfo } from './dto/ApiDto';

/**
 * 应用模型层（应用状态：用户/下载/阅读/视图模型 + respToJmAlbumInfo 转换）
 *
 * API DTO 在 dto/ApiDto.ets（零依赖最底层）。
 * 一部漫画的固有实体与转换在 ComicAlbum.ets，实时数据与评论转换在 ComicAlbumRealtime.ets。
 */

// ─── JSON 序列化接口 ───

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

// ─── 规范化列表项（DTO → 本地模型的中间形态，逐步由 ComicAlbum 取代）──

export interface JmAlbumInfo {
  id: number;
  name: string;
  author: string[];
  image: string;
  description: string;
  category: string;
  total_views?: string;
  total_picture?: string;
  likes?: string;
  addtime?: string;
  series?: JmAlbumSeries[];
}

export function respToJmAlbumInfo(info: RespJmAlbumInfo): JmAlbumInfo {
  return {
    id: Number(info.id) || 0,
    name: info.name,
    author: (typeof info.author === 'string' ? [info.author as string] : (info.author as string[])) ?? [],
    image: info.image,
    description: info.description,
    category: (typeof info.category === 'string' ? info.category : (info.category ? info.category.title : '')) ?? '',
    total_views: info.total_views,
    total_picture: info.total_picture,
    likes: info.likes,
    addtime: info.addtime,
    series: info.series,
  };
}

// ─── 收藏夹操作状态 ───

export enum FavoriteFolderType {
  ADD = 'add',
  EDIT = 'edit',
  MOVE = 'move',
  DELETE = 'del',
}

export interface FavoriteFolderParams {
  type: FavoriteFolderType;
  folderId?: string;
  folderName?: string;
  albumId?: string;
}

// ─── 登录/用户会话（应用状态）──

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
  sessionToken: string = '';
  isLoggedIn: boolean = false;

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

// ─── 下载/阅读生命周期状态（章节账本）──

/**
 * 章节状态账本：记录某一章的图片版本与生命周期状态。
 * 落盘于 filesDir/JMComic/albums/{albumId}/manifests/{photoId}.json，由 ComicLibrary 读写。
 */
export interface ChapterManifest {
  photoId: string;
  albumId: number;
  albumName: string;
  chapterName: string;
  /** 元数据指纹 = hash(scrambleId + imgNames)，判断是否需要整体换版 */
  fingerprint: string;
  /** 当前已落盘 PNG 对应的解码参数（换版后全部页需重下） */
  scrambleId: number;
  imgNames: string[];
  lastReadAt: number;
  downloadedAt: number;
  exportedAt: number;
}

export enum DownloadStatus {
  QUEUED = 'queued',
  DOWNLOADING = 'downloading',
  PAUSED = 'paused',
  DONE = 'done',
  ERROR = 'error',
}

/** 单个下载任务（一个章节） */
@Observed
export class DownloadTask {
  taskId: string = '';
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
  addTime: number = 0;

  getProgress(): number {
    if (this.totalImages === 0) return 0;
    return Math.floor(this.completedImages / this.totalImages * 100);
  }

  getStatusText(): string {
    switch (this.status) {
      case DownloadStatus.QUEUED: return '等待中';
      case DownloadStatus.DOWNLOADING: return '下载中';
      case DownloadStatus.PAUSED: return '已暂停';
      case DownloadStatus.DONE: return '已完成';
      case DownloadStatus.ERROR: return '失败';
      default: return '';
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

// ─── 显示用视图模型（逐步由 ComicAlbum 派生取代）──

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

  static fromApiInfo(info: RespJmAlbumInfo, coverUrl: string): AlbumViewModel {
    let vm = new AlbumViewModel();
    let jmAlbumInfo: JmAlbumInfo = respToJmAlbumInfo(info);
    vm.id = jmAlbumInfo.id;
    vm.name = jmAlbumInfo.name;
    vm.description = jmAlbumInfo.description;
    vm.author = jmAlbumInfo.author.length === 1 ? jmAlbumInfo.author[0] : jmAlbumInfo.author.join(', ');
    vm.category = jmAlbumInfo.category;
    vm.totalViews = info.total_views || '0';
    vm.totalPicture = info.total_picture || '0';
    vm.likes = info.likes || '0';
    vm.coverUrl = coverUrl;
    return vm;
  }

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

  static fromJSONArray(arr: IAlbumViewModelJSON[]): AlbumViewModel[] {
    return arr.map(item => AlbumViewModel.fromJSON(item));
  }
}

export class PhotoViewModel {
  id: number = 0;
  photoId: string = '';
  name: string = '';
  index: number = 0;
  scrambleId: number = 0;
  isRead: boolean = false;

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

export class ImageViewModel {
  imgName: string = '';
  imgUrl: string = '';
  downloadUrl: string = '';
}
