import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { JmAlbumDetail, JmPromoteSection, RespJmAlbumInfo } from '../models/dto/ApiDto';
import {
  applyAlbumPatch, albumPatchFromDetail, albumPatchFromList,
  ComicAlbum, ComicAlbumPatch, ComicChapter, ComicCategory, ComicRelatedRef, emptyAlbum
} from '../models/ComicAlbum';
import {
  FeedAlbums, FeedAlbumsSection, feedFromList, feedFromPromote
} from '../models/AlbumFeed';
import {
  AppDatabase, TABLE_ALBUM, TABLE_CHAPTER, TABLE_COMMENT
} from './AppDatabase';
import { FeedDao } from './FeedDao';

/**
 * 一部漫画的持久化入口（DAO）
 *
 * 表分工见 AppDatabase.DDL。本类只管读写，不做 DTO 转换——
 * DTO → 实体在 models/ComicAlbum 的纯函数里，写库时把实体拆成行。
 *
 * 读接口同步（querySqlSync），因此 updateAlbum 这类「读-改-写」不必整条链异步化。
 *
 * 图片路径不落库，由 ComicLibrary 用 (albumId, photoId, idx) 现推；
 * 章节图片元数据也只有一份，在 ComicLibrary 的 meta.json 里，本类不存副本。
 */
export class AlbumDao {
  private static instance: AlbumDao | null = null;
  private static staticBaseDir: string = '';
  /**
   * 设置页「刷新内容」快照，由 CacheManager 读到设置后同步过来
   * （DAO 不反向 import common 层）。
   * - refreshFields：联网刷新是否覆盖本地已存的漫画字段
   * - refreshCovers：封面名是否跟着刷新走（关闭时连 image_name 都不更新）
   */
  static refreshFields: boolean = true;
  static refreshCovers: boolean = true;
  private db: relationalStore.RdbStore;

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  static async getInstance(): Promise<AlbumDao> {
    if (AlbumDao.instance === null) {
      let db = await AppDatabase.getInstance();
      AlbumDao.instance = new AlbumDao(db);
    }
    return AlbumDao.instance;
  }

  /** 一部漫画的根目录（章节 PNG 落在这里；表不记路径，只记目录与顺序） */
  static albumRoot(albumId: number): string {
    if (AlbumDao.staticBaseDir === '') {
      let ctx = getContext() as common.UIAbilityContext;
      AlbumDao.staticBaseDir = `${ctx.filesDir}/JMComic/albums`;
    }
    return `${AlbumDao.staticBaseDir}/${albumId}`;
  }

  // ─── 目录读写 ───

  /** 读一部漫画：album 一行 + chapter 按 sort 组装，未命中返回 null */
  get(albumId: number): ComicAlbum | null {
    let rs = this.db.querySqlSync(`SELECT * FROM ${TABLE_ALBUM} WHERE id = ?`, [albumId]);
    try {
      if (!rs.goToFirstRow()) return null;
      let album = AlbumDao.albumFromRow(rs);
      album.chapters = this.readChapters(albumId);
      return album;
    } finally {
      rs.close();
    }
  }

  private readChapters(albumId: number): ComicChapter[] {
    let rs = this.db.querySqlSync(
      `SELECT photo_id, id, title, sort FROM ${TABLE_CHAPTER}
       WHERE album_id = ? ORDER BY sort`, [albumId]);
    let chapters: ComicChapter[] = [];
    try {
      while (rs.goToNextRow()) {
        chapters.push({
          id: rs.getLong(rs.getColumnIndex('id')),
          photoId: rs.getString(rs.getColumnIndex('photo_id')),
          title: rs.getString(rs.getColumnIndex('title')),
          sort: rs.getLong(rs.getColumnIndex('sort')),
        } as ComicChapter);
      }
    } finally {
      rs.close();
    }
    return chapters;
  }

  /**
   * 落库：album 整行 UPSERT + 章节目录全量替换，同一事务。
   * album 表 27 列一次写全：固有字段、统计/用户态、拉取游标。
   * fetchedAt === 0 表示统计从未拉取，此时四列写 NULL（与建表时的 NULL 语义一致）。
   */
  save(album: ComicAlbum): void {
    this.db.beginTransaction();
    try {
      this.db.executeSync(
        `INSERT INTO ${TABLE_ALBUM} (
           id, series_id, title, description, image_name, add_time,
           authors, category_id, category_title, sub_category_id, sub_category_title,
           tags, works, actors, is_aids, price, total_picture, updated_at,
           liked, is_favorite, purchased, total_views, likes, comment_total, related,
           fetched_at, comment_page, comment_fetched_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           series_id          = excluded.series_id,
           title              = excluded.title,
           description        = excluded.description,
           image_name         = excluded.image_name,
           add_time           = excluded.add_time,
           authors            = excluded.authors,
           category_id        = excluded.category_id,
           category_title     = excluded.category_title,
           sub_category_id    = excluded.sub_category_id,
           sub_category_title = excluded.sub_category_title,
           tags               = excluded.tags,
           works              = excluded.works,
           actors             = excluded.actors,
           is_aids            = excluded.is_aids,
           price              = excluded.price,
           total_picture      = excluded.total_picture,
           updated_at         = excluded.updated_at,
           liked              = excluded.liked,
           is_favorite        = excluded.is_favorite,
           purchased          = excluded.purchased,
           total_views        = excluded.total_views,
           likes              = excluded.likes,
           comment_total      = excluded.comment_total,
           related            = excluded.related,
           fetched_at         = excluded.fetched_at,
           comment_page       = excluded.comment_page,
           comment_fetched_at = excluded.comment_fetched_at`,
        [album.id, album.seriesId, album.title, album.description, album.imageName,
          album.addTime, JSON.stringify(album.authors),
          album.category.id, album.category.title,
          album.subCategory.id, album.subCategory.title,
          JSON.stringify(album.tags), JSON.stringify(album.works), JSON.stringify(album.actors),
          album.isAids ? 1 : 0, album.price, album.totalPicture, album.updatedAt,
          album.liked ? 1 : 0, album.isFavorite ? 1 : 0, album.purchased,
          AlbumDao.fetchedValue(album.totalViews, album.fetchedAt),
          AlbumDao.fetchedValue(album.likes, album.fetchedAt),
          AlbumDao.fetchedValue(album.commentTotal, album.fetchedAt),
          AlbumDao.fetchedValue(JSON.stringify(album.related), album.fetchedAt),
          album.fetchedAt, album.commentPage, album.commentFetchedAt]);
      this.db.executeSync(`DELETE FROM ${TABLE_CHAPTER} WHERE album_id = ?`, [album.id]);
      for (let ch of album.chapters) {
        this.db.executeSync(
          `INSERT INTO ${TABLE_CHAPTER} (album_id, photo_id, id, title, sort)
           VALUES (?, ?, ?, ?, ?)`,
          [album.id, ch.photoId, ch.id, ch.title, ch.sort]);
      }
      this.db.commit();
    } catch (e) {
      this.db.rollBack();
      console.warn(`[AlbumDao] save failed ${album.id}: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 部分更新：只覆盖 patch 中出现的字段，其余保持原值。
   * 实体不存在时按空骨架创建，因此「首页只拿到封面标题」也能先落一份摘要。
   */
  updateAlbum(albumId: number, patch: ComicAlbumPatch): boolean {
    let existing = this.get(albumId);
    if (existing !== null && !AlbumDao.refreshFields) {
      // 字段刷新关闭：本地已有内容原样保留，只把封面名（封面维度的版本标识）透下去；
      // 封面也关掉时没有任何要写的字段，整行 UPSERT 一并省掉
      patch = AlbumDao.coverOnlyPatch(patch);
      if (patch.imageName === undefined) return true;
    }
    let album = existing ?? emptyAlbum(albumId);
    applyAlbumPatch(album, patch);
    album.updatedAt = Date.now();
    this.save(album);
    return true;
  }

  /** 从联网 patch 里只留下封面名（封面开关关闭时连它也不留） */
  private static coverOnlyPatch(patch: ComicAlbumPatch): ComicAlbumPatch {
    let result: ComicAlbumPatch = {} as ComicAlbumPatch;
    if (AlbumDao.refreshCovers) result.imageName = patch.imageName;
    return result;
  }

  private static albumFromRow(rs: relationalStore.ResultSet): ComicAlbum {
    return {
      id: rs.getLong(rs.getColumnIndex('id')),
      seriesId: rs.getString(rs.getColumnIndex('series_id')),
      title: rs.getString(rs.getColumnIndex('title')),
      description: rs.getString(rs.getColumnIndex('description')),
      imageName: rs.getString(rs.getColumnIndex('image_name')),
      addTime: rs.getString(rs.getColumnIndex('add_time')),
      authors: AlbumDao.jsonArray(rs.getString(rs.getColumnIndex('authors'))),
      category: {
        id: rs.getLong(rs.getColumnIndex('category_id')),
        title: rs.getString(rs.getColumnIndex('category_title')),
      } as ComicCategory,
      subCategory: {
        id: rs.getLong(rs.getColumnIndex('sub_category_id')),
        title: rs.getString(rs.getColumnIndex('sub_category_title')),
      } as ComicCategory,
      tags: AlbumDao.jsonArray(rs.getString(rs.getColumnIndex('tags'))),
      works: AlbumDao.jsonArray(rs.getString(rs.getColumnIndex('works'))),
      actors: AlbumDao.jsonArray(rs.getString(rs.getColumnIndex('actors'))),
      isAids: rs.getLong(rs.getColumnIndex('is_aids')) === 1,
      price: rs.getString(rs.getColumnIndex('price')),
      chapters: [],
      totalPicture: rs.getString(rs.getColumnIndex('total_picture')),
      totalViews: AlbumDao.nullString(rs, 'total_views'),
      likes: AlbumDao.nullString(rs, 'likes'),
      commentTotal: AlbumDao.nullLong(rs, 'comment_total'),
      liked: rs.getLong(rs.getColumnIndex('liked')) === 1,
      isFavorite: rs.getLong(rs.getColumnIndex('is_favorite')) === 1,
      purchased: rs.getString(rs.getColumnIndex('purchased')),
      related: AlbumDao.jsonRelated(rs.getString(rs.getColumnIndex('related'))),
      fetchedAt: rs.getLong(rs.getColumnIndex('fetched_at')),
      commentPage: rs.getLong(rs.getColumnIndex('comment_page')),
      commentFetchedAt: rs.getLong(rs.getColumnIndex('comment_fetched_at')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
    } as ComicAlbum;
  }

  /** 统计列写入值：从未拉取时写 NULL，使「没拉过」与「拉到了 0」可区分 */
  private static fetchedValue(value: string | number, fetchedAt: number): relationalStore.ValueType {
    return fetchedAt === 0 ? null : value;
  }

  /** 可空 TEXT 列：NULL → '' */
  private static nullString(rs: relationalStore.ResultSet, column: string): string {
    let idx = rs.getColumnIndex(column);
    return rs.isColumnNull(idx) ? '' : rs.getString(idx);
  }

  /** 可空 INTEGER 列：NULL → 0 */
  private static nullLong(rs: relationalStore.ResultSet, column: string): number {
    let idx = rs.getColumnIndex(column);
    return rs.isColumnNull(idx) ? 0 : rs.getLong(idx);
  }

  private static jsonArray(raw: string): string[] {
    if (!raw) return [];
    try {
      return JSON.parse(raw) as string[];
    } catch {
      return [];
    }
  }

  private static jsonRelated(raw: string): ComicRelatedRef[] {
    if (!raw) return [];
    try {
      return JSON.parse(raw) as ComicRelatedRef[];
    } catch {
      return [];
    }
  }

  /** 枚举库中已有的漫画 ID（供清理、统计、批量操作使用） */
  getAllAlbumIds(): number[] {
    let ids: number[] = [];
    let rs = this.db.querySqlSync(`SELECT id FROM ${TABLE_ALBUM} ORDER BY updated_at DESC`);
    try {
      while (rs.goToNextRow()) {
        ids.push(rs.getLong(rs.getColumnIndex('id')));
      }
    } finally {
      rs.close();
    }
    return ids;
  }

  /** 清空全部漫画（三张表的行 + 章节 PNG），返回清除的漫画数 */
  clearAll(): number {
    let ids = this.getAllAlbumIds();
    for (let id of ids) {
      this.remove(id);
    }
    console.info(`[AlbumDao] cleared ${ids.length} albums`);
    return ids.length;
  }

  /** 删除整部漫画：三张表里该 album 的行 + 磁盘目录 */
  remove(albumId: number): void {
    this.db.beginTransaction();
    try {
      this.db.executeSync(`DELETE FROM ${TABLE_CHAPTER} WHERE album_id = ?`, [albumId]);
      this.db.executeSync(`DELETE FROM ${TABLE_COMMENT} WHERE album_id = ?`, [albumId]);
      this.db.executeSync(`DELETE FROM ${TABLE_ALBUM} WHERE id = ?`, [albumId]);
      this.db.commit();
    } catch (e) {
      this.db.rollBack();
      console.warn(`[AlbumDao] remove rows failed ${albumId}: ${JSON.stringify(e)}`);
      return;
    }
    try {
      let root = AlbumDao.albumRoot(albumId);
      if (fileIo.accessSync(root)) fileIo.rmdirSync(root);
    } catch (e) {
      console.warn(`[AlbumDao] remove dir failed ${albumId}: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 本地磁盘上已有图的章节 photoId 集合（目录名固定以 _photoId 结尾）。
   * 服务器目录滞后、丢掉了本地已下载的章节时，用它把目录项补回来。
   */
  private static localChapterIds(albumId: number): Set<string> {
    let ids = new Set<string>();
    let chaptersDir = `${AlbumDao.albumRoot(albumId)}/chapters`;
    try {
      if (!fileIo.accessSync(chaptersDir)) return ids;
      for (let dir of fileIo.listFileSync(chaptersDir)) {
        let sep = dir.lastIndexOf('_');
        if (sep >= 0 && sep < dir.length - 1) {
          ids.add(dir.substring(sep + 1));
        }
      }
    } catch (e) {
      console.warn(`[AlbumDao] list chapters failed ${albumId}: ${JSON.stringify(e)}`);
    }
    return ids;
  }

  /**
   * 只改收藏态：收藏是详情页的即时动作，不能整本重存，
   * 否则会把「没拉取过」的统计列覆盖成旧值。
   */
  markFavorite(albumId: number, favorite: boolean): void {
    this.db.executeSync(
      `UPDATE ${TABLE_ALBUM} SET is_favorite = ? WHERE id = ?`,
      [favorite ? 1 : 0, albumId]);
  }

  static async setFavorite(albumId: number, favorite: boolean): Promise<void> {
    let dao = await AlbumDao.getInstance();
    dao.markFavorite(albumId, favorite);
  }

  // ─── 列表读取（列表页只渲染摘要，不读章节）───

  /**
   * 按 id 顺序批量读摘要：一次 IN 查询，缺实体的 id 直接跳过。
   * 列表页不需要章节，避免为每本再查一次 chapter 表。
   */
  getSummaries(ids: number[]): ComicAlbum[] {
    if (ids.length === 0) return [];
    let marks: string[] = [];
    let args: relationalStore.ValueType[] = [];
    for (let id of ids) {
      marks.push('?');
      args.push(id);
    }
    let rs = this.db.querySqlSync(
      `SELECT * FROM ${TABLE_ALBUM} WHERE id IN (${marks.join(',')})`, args);
    let byId: Map<number, ComicAlbum> = new Map<number, ComicAlbum>();
    try {
      while (rs.goToNextRow()) {
        let album = AlbumDao.albumFromRow(rs);
        byId.set(album.id, album);
      }
    } finally {
      rs.close();
    }
    let result: ComicAlbum[] = [];
    for (let id of ids) {
      let album = byId.get(id);
      if (album !== undefined) result.push(album);
    }
    return result;
  }

  // ─── 列表读写（feed 顺序 + album 内容）───

  /**
   * 列表落库：逐项写摘要（只覆盖摘要字段），再整表替换顺序。
   * 写完不返回实体——调用方必须从库里读回来，网络响应不直接进页面。
   */
  static async saveFeed(key: string, list: RespJmAlbumInfo[], total: number): Promise<void> {
    let dao = await AlbumDao.getInstance();
    for (let info of list) {
      let albumId = Number(info.id) || 0;
      if (albumId <= 0) continue;
      dao.updateAlbum(albumId, albumPatchFromList(info));
    }
    let feedDao = await FeedDao.getInstance();
    feedDao.save(feedFromList(key, list, total));
  }

  /** 首页推广落库：多分区，保留服务器给的段顺序与段标题 */
  static async savePromoteFeed(key: string, sections: JmPromoteSection[]): Promise<void> {
    let dao = await AlbumDao.getInstance();
    for (let section of sections) {
      for (let info of section.content) {
        let albumId = Number(info.id) || 0;
        if (albumId <= 0) continue;
        dao.updateAlbum(albumId, albumPatchFromList(info));
      }
    }
    let feedDao = await FeedDao.getInstance();
    feedDao.save(feedFromPromote(key, sections));
  }

  /**
   * 手动刷新（下拉）落库：只重建列表成员与顺序，用来拉新漫画。
   * 已有作品的字段与封面一个都不写——那是「刷新内容」与自动刷新的职责。
   * 本地没有的条目必须写一次摘要骨架：loadFeed 用 feed_item 的 id 去 album 表取实体，
   * 缺行会被 getSummaries 跳过，表现为「拉到了新漫画但列表里不显示」。
   */
  static async saveFeedKeepList(key: string, list: RespJmAlbumInfo[], total: number): Promise<void> {
    let dao = await AlbumDao.getInstance();
    AlbumDao.ensureSkeletons(dao, list);
    let feedDao = await FeedDao.getInstance();
    feedDao.save(feedFromList(key, list, total));
  }

  /** 推广分区的手动刷新落库：与 saveFeedKeepList 同规则，按分区逐个补缺 */
  static async savePromoteFeedKeepList(key: string, sections: JmPromoteSection[]): Promise<void> {
    let dao = await AlbumDao.getInstance();
    for (let section of sections) {
      AlbumDao.ensureSkeletons(dao, section.content);
    }
    let feedDao = await FeedDao.getInstance();
    feedDao.save(feedFromPromote(key, sections));
  }

  /** 只为本地缺失的条目建摘要骨架：已有实体直接跳过，不触发任何覆盖 */
  private static ensureSkeletons(dao: AlbumDao, list: RespJmAlbumInfo[]): void {
    let ids: number[] = [];
    for (let info of list) {
      let albumId = Number(info.id) || 0;
      if (albumId > 0) ids.push(albumId);
    }
    if (ids.length === 0) return;
    let existing: Set<number> = new Set<number>();
    for (let album of dao.getSummaries(ids)) {
      existing.add(album.id);
    }
    for (let info of list) {
      let albumId = Number(info.id) || 0;
      if (albumId <= 0 || existing.has(albumId)) continue;
      dao.updateAlbum(albumId, albumPatchFromList(info));
      // 同一批里重复出现时不必再写一遍
      existing.add(albumId);
    }
  }

  /**
   * 按顺序读回列表实体：分区顺序、分区内顺序都由库决定。
   * 未命中（本地没有这个列表）返回 sections 为空的快照，页面据此决定要不要联网。
   */
  static async loadFeed(key: string): Promise<FeedAlbums> {
    let feedDao = await FeedDao.getInstance();
    let feed = feedDao.get(key);
    if (feed === null) {
      return { total: -1, updatedAt: 0, sections: [] };
    }
    let dao = await AlbumDao.getInstance();
    let sections: FeedAlbumsSection[] = [];
    for (let section of feed.sections) {
      sections.push({
        key: section.key,
        title: section.title,
        albums: dao.getSummaries(section.ids),
      });
    }
    return { total: feed.total, updatedAt: feed.updatedAt, sections: sections };
  }

  /**
   * 分页列表已落库的页码，升序。
   * prefix 形如 `cat:0_mr:p`，页键为 prefix + 页码。
   */
  static async feedPageNumbers(prefix: string): Promise<number[]> {
    let feedDao = await FeedDao.getInstance();
    let keys = feedDao.keysWithPrefix(prefix);
    let pages: number[] = [];
    for (let key of keys) {
      let page = Number(key.substring(prefix.length));
      if (!isNaN(page)) pages.push(page);
    }
    pages.sort((a: number, b: number) => a - b);
    return pages;
  }

  /** 作废一个分页列表（含其所有页），下次读取会重新联网 */
  static async clearFeedPrefix(prefix: string): Promise<void> {
    let feedDao = await FeedDao.getInstance();
    feedDao.removePrefix(prefix);
  }

  /** 读一本的完整实体（含章节目录）：页面读库的静态入口 */
  static async load(albumId: number): Promise<ComicAlbum | null> {
    let dao = await AlbumDao.getInstance();
    return dao.get(albumId);
  }

  /** 按页码升序读回一个分页列表的全部已落库页 */
  static async loadFeedPages(prefix: string): Promise<FeedAlbums[]> {
    let pages = await AlbumDao.feedPageNumbers(prefix);
    let result: FeedAlbums[] = [];
    for (let page of pages) {
      result.push(await AlbumDao.loadFeed(`${prefix}${page}`));
    }
    return result;
  }

  // ─── 列表 / 详情入口 ───

  /**
   * 列表项 → 只更新摘要字段（标题/封面/作者/简介/分类），不动章节与详情字段。
   * 首页、搜索、收藏等列表页用它，避免用「只有摘要」的数据覆盖掉详情。
   */
  static async saveFromList(info: RespJmAlbumInfo): Promise<ComicAlbum | null> {
    let albumId = Number(info.id) || 0;
    if (albumId <= 0) return null;
    let dao = await AlbumDao.getInstance();
    dao.updateAlbum(albumId, albumPatchFromList(info));
    return dao.get(albumId);
  }

  /**
   * 详情 DTO → 部分更新（只覆盖详情接口真正返回的字段）。
   * 刷新时保留「服务器目录里没有、但本地已有内容」的章节——
   * 这类章节通常是 series 滞后或服务器后来新增的，丢弃会导致已读章节凭空消失。
   */
  static async saveFromDetail(dto: JmAlbumDetail): Promise<ComicAlbum | null> {
    let dao = await AlbumDao.getInstance();
    let patch = albumPatchFromDetail(dto);
    let old = dao.get(dto.id);
    if (old && patch.chapters) {
      let freshIds = new Set<string>();
      for (let ch of patch.chapters) {
        freshIds.add(ch.photoId);
      }
      let localIds = AlbumDao.localChapterIds(dto.id);
      for (let ch of old.chapters) {
        if (!freshIds.has(ch.photoId) && localIds.has(ch.photoId)) {
          patch.chapters.push(ch);
        }
      }
      patch.chapters.sort((a: ComicChapter, b: ComicChapter) => a.sort - b.sort);
    }
    dao.updateAlbum(dto.id, patch);
    return dao.get(dto.id);
  }
}
