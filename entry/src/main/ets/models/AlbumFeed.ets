import { JmPromoteSection, RespJmAlbumInfo } from './dto/ApiDto';
import { ComicAlbum } from './ComicAlbum';

/**
 * 列表顺序（纯类型 + 纯函数，无 IO）
 *
 * 实体层 ComicAlbum 回答的是「某部漫画是什么」，
 * 回答不了「首页有哪些漫画、按什么顺序、归在哪个标题下」。
 * 同一部漫画可以同时出现在首页、分类、搜索、收藏里，位置各不相同，
 * 所以列表顺序单独存一层，只存 id 顺序与标题，不存漫画内容。
 *
 * 落库与读取在 storage/FeedDao，表结构见 AppDatabase.DDL：
 * feed（列表一行）/ feed_section（分区标题与顺序）/ feed_item（分区内 id 顺序）。
 *
 * 渲染：ids → AlbumDao.get(id) → AlbumViewModel，实体缺失的 id 直接跳过。
 */
export interface Feed {
  /** 列表标识，见下方 FEED_* 常量 */
  key: string;
  /** 分区；单列表也用一个分区承载，此时 section.key 与 feed.key 相同、title 为空 */
  sections: FeedSection[];
  /** 服务器返回的总数，用于判断还有没有更多；-1 表示未知 */
  total: number;
  /** 写入时间 */
  updatedAt: number;
}

/** 一个列表分区：一个标题 + 一串漫画 id */
export interface FeedSection {
  /** 分区标识，如 promote-0 / latest */
  key: string;
  /** 显示用标题，服务器给的分区名；无标题（单列表）时为空串 */
  title: string;
  /** 该分区内的漫画 id，数组顺序即显示顺序 */
  ids: number[];
}

/** 首页推广分区（多分区，每段带服务器给的标题） */
export const FEED_HOME_PROMOTE: string = 'home:promote';

/** 首页最新上传（单分区，无标题） */
export const FEED_HOME_LATEST: string = 'home:latest';

/** 列表响应 → 单分区快照（首页最新、分类页、搜索、收藏、追番） */
export function feedFromList(key: string, list: RespJmAlbumInfo[], total: number): Feed {
  return {
    key: key,
    sections: [
      {
        key: key,
        title: '',
        ids: idsOf(list),
      } as FeedSection,
    ],
    total: total,
    updatedAt: Date.now(),
  } as Feed;
}

/** 首页推广响应 → 多分区快照（保留服务器给的段顺序与段标题） */
export function feedFromPromote(key: string, sections: JmPromoteSection[]): Feed {
  let result: FeedSection[] = [];
  for (let i = 0; i < sections.length; i++) {
    let section = sections[i];
    result.push({
      key: `promote-${i}`,
      title: section.title || '',
      ids: idsOf(section.content || []),
    } as FeedSection);
  }
  return {
    key: key,
    sections: result,
    total: -1,
    updatedAt: Date.now(),
  } as Feed;
}

/** 列表项 → id 顺序（跳过解析不出 id 的脏数据） */
function idsOf(list: RespJmAlbumInfo[]): number[] {
  let ids: number[] = [];
  for (let item of list) {
    let id = Number(item.id);
    if (!isNaN(id) && id > 0) ids.push(id);
  }
  return ids;
}

// ─── 读库结果（页面渲染的唯一入口）───

/**
 * 一个分区 + 该分区内的实体。
 * 由 FeedDao 的顺序与 AlbumDao 的实体拼合而成，缺实体的 id 已被跳过。
 */
export interface FeedAlbumsSection {
  key: string;
  title: string;
  albums: ComicAlbum[];
}

/** 整个列表读回来的样子：页面只认这个，不认网络响应 */
export interface FeedAlbums {
  /** 服务器总数，-1 表示未知 */
  total: number;
  /** 落库时间，用于判断本地是否为空/过期 */
  updatedAt: number;
  sections: FeedAlbumsSection[];
}
