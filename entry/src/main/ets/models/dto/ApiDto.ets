/**
 * API 传输 DTO（最底层，零依赖）
 *
 * 服务器响应的原样快照：字段命名/类型/嵌套结构与服务器逐字一致，
 * 供 ApiService.decryptResponse<T>() 直接 JSON.parse as T 使用。
 * 不做规范化、不含逻辑；DTO → 本地模型的转换在 Album.ets（应用层转换函数）。
 */

// ─── 专辑 / 列表 ───

export interface JmPromoteSection {
  title: string;
  content: RespJmAlbumInfo[];
}

export interface RespJmAlbumInfo {
  id: number | string;
  name: string;
  author: string | string[];
  image: string;
  description: string;
  category: CategoryBean | string;
  total_views?: string;
  total_picture?: string;
  likes?: string;
  addtime?: string;
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
  author: string | string[];
  description: string | null;
  /** 收录时间（Unix 时间戳字符串） */
  addtime?: string;
  category?: CategoryBean;
  category_sub?: CategoryBean;
  total_views: string;
  likes: string;
  series: JmAlbumSeries[];
  series_id: string;
  /** 评论总数（服务器返回数值） */
  comment_total: number;
  tags: string[];
  works: string[];
  actors?: string[];
  related_list?: JmRelatedWork[];
  liked?: boolean;
  is_favorite?: boolean;
  /** 成人内容标识 */
  is_aids?: boolean;
  /** 价格（通常为空字符串） */
  price?: string;
  /** 是否已购买（通常为空字符串） */
  purchased?: string;
  /** 封面文件名（单张；图片数组只出现在 comic_read 响应） */
  image?: string;
}

export interface JmPhotoInfo {
  id: number;
  photo_id: string;
  name: string;
  index: number;
  scramble_id: number;
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
  description?: string;
  category?: CategoryBean;
  category_sub?: CategoryBean;
}

export interface JmActorInfo {
  id: number;
  name: string;
  image: string | null;
}

// ─── 章节 / 图片 ───

export interface JmImageInfo {
  img_name: string;
  img_url: string;
  download_url: string;
}

export interface JmPictureResp {
  id: number;
  photo_id: string;
  name: string;
  images: JmImageInfo[];
  scramble_id: number;
}

export interface PictureData {
  pictures: JmPictureResp;
}

// ─── 通用响应封装 ───

export interface JmApiResponse<T> {
  code: number;
  message: string;
  data: T;
}

export interface SearchResultData {
  content: RespJmAlbumInfo[];
  total: string;
}

export interface AlbumDetailData {
  album: JmAlbumDetail;
}

// ─── 收藏 ───

export interface FavoriteFolderItem {
  FID: string;
  name: string;
}

export interface FavoriteAlbumItem {
  id: string;
  name: string;
  author: string | string[];
  description: string;
  image: string;
  category: CategoryBean;
  category_sub: CategoryBean;
}

export interface FavoritePageData {
  list: FavoriteAlbumItem[];
  folder_list: FavoriteFolderItem[];
  total: number;
  count?: number;
}

export interface FavoriteActionResult {
  status: string;
  msg: string;
}

export interface WatchListData {
  list: RespJmAlbumInfo[];
}

// ─── 登录 / 用户 ───

export interface JmUserData {
  uid: string;
  username: string;
  email: string;
  emailverified: string;
  photo: string;
  fname: string;
  gender: string;
  message: string;
  coin: number;
  album_favorites: number;
  s: string;
  level_name: string;
  level: number;
  nextLevelExp: number;
  exp: string;
  expPercent: number;
  badges: string[];
  album_favorites_max: number;
}

// ─── 评论 ───

export interface CommentInfoRaw {
  CID: string;
  UID: string;
  username: string;
  content: string;
  likes: number;
  addtime: string;
  photo: string;
  name: string;
  AID: string;
  expinfo: CommentExpInfo;
  replys: CommentInfoRaw[];
}

export interface CommentExpInfo {
  level: string;
  level_name: string;
}

export interface CommentPageData {
  list: CommentInfoRaw[];
  total: number;
}

export interface SendCommentData {
  msg: string;
}
