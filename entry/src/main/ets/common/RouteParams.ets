import { RespJmAlbumInfo } from '../models/dto/ApiDto';

/**
 * Navigation 路由参数集中定义（docs/Navigation路由规范.md §5：Object 传递、接收侧 as 收窄）。
 * 发送侧字面量须显式对应具名接口（arkts-no-untyped-obj-literals），
 * 接收侧统一 `ctx.pathInfo.param as XxxParams` 收窄。
 */

/** AlbumDetailPage：albumId 必传；专辑名用于标题/收藏态展示 */
export interface AlbumDetailParams {
  albumId: number;
  albumName: string;
}

/** SearchPage：keyword 可空（从顶部搜索入口进入时无参） */
export interface SearchPageParams {
  keyword: string;
}

/** ImageViewerPage：chaptersStr 为章节列表 JSON 串（可选，页内切章用） */
export interface ImageViewerParams {
  photoId: string;
  photoName: string;
  scrambleId: number;
  albumId: number;
  albumName: string;
  chaptersStr?: string;
  currentChapterIndex?: number;
}

/** AlbumCommentPage */
export interface CommentPageParams {
  albumId: number;
  albumName: string;
}

/** SectionMorePage：initialAlbums 为分区首屏数据（免首屏请求） */
export interface SectionMoreParams {
  sectionTitle: string;
  initialAlbums: RespJmAlbumInfo[];
  source?: string;
}
