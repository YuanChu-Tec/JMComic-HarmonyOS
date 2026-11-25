import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { JmAlbumDetail, JmPromoteSection, RespJmAlbumInfo } from '../models/dto/ApiDto';
import {
  albumPatchFromDetail, albumPatchFromList,
  ComicAlbum, ComicAlbumPatch, ComicChapter, ComicCategory, ComicRelatedRef
} from '../models/ComicAlbum';
import {
  FeedAlbums, FeedAlbumsSection, feedFromList, feedFromPromote
} from '../models/AlbumFeed';
import {
  AppDatabase, TABLE_ALBUM, TABLE_CHAPTER, TABLE_COMMENT, TABLE_PREF
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
   * 设置页「刷新内容」的节流参数，由 CacheManager 读到设置后同步过来
   * （DAO 不反向 import common 层）。单位 ms：
   * - fieldTtlMs：漫画字段（标题/作者/章节等）最多多久重建一次
   * - coverTtlMs：封面最多多久换一次（旧图未到期时继续用）
   * 0 表示每次都重建（未初始化时的安全默认），MAX 表示不自动重建。
   */
  static fieldTtlMs: number = 0;
  static coverTtlMs: number = 0;
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
   * 部分更新：只写 patch 里出现的列，其余列一律不动。
   *
   * 每次进页面都会联网，但落库范围由「当前页面真正拿到什么」决定：
   * - 列表页只落摘要列（标题/封面/作者/分类/图片总数）；
   * - 详情页落详情列与章节目录；
   * - 没出现的列保持原值，因此本地已下载的目录、统计不会被空骨架覆盖。
   *
   * 已有记录时，字段列还受「刷新内容·漫画字段」间隔节流：未到期只透传
   * 封面名与章节目录（新章节是本地没有的内容，立即可见）。
   */
  updateAlbum(albumId: number, patch: ComicAlbumPatch): boolean {
    let existing = this.get(albumId);
    let fieldsDue = existing === null || AlbumDao.fieldsDue(existing);
    if (!fieldsDue) {
      patch = AlbumDao.refreshOnlyPatch(patch);
      if (patch.imageName === undefined && patch.chapters === undefined) return true;
    }
    // updated_at 记为「上次联网落库时间」；字段自身是否重建另记在 pref 的 fields_at 里
    let at = Date.now();
    this.db.beginTransaction();
    try {
      this.upsertPatch(albumId, patch, at, existing);
      if (patch.chapters !== undefined) this.replaceChapters(albumId, patch.chapters);
      this.db.commit();
    } catch (e) {
      this.db.rollBack();
      console.warn(`[AlbumDao] update failed ${albumId}: ${JSON.stringify(e)}`);
      return false;
    }
    if (fieldsDue) AlbumDao.markFieldsAt(albumId, at);
    return true;
  }

  /**
   * 列级 UPSERT：INSERT 只带 patch 出现的列（未出现的走 DDL 默认值），
   * 冲突时也只更新这些列。统计四列从未拉取（fetchedAt === 0）时写 NULL，
   * 使「没拉过」与「拉到了 0」可区分。
   */
  private upsertPatch(albumId: number, patch: ComicAlbumPatch, at: number,
    existing: ComicAlbum | null): void {
    let cols: string[] = ['id', 'updated_at'];
    let vals: relationalStore.ValueType[] = [albumId, at];
    if (patch.seriesId !== undefined) {
      cols.push('series_id');
      vals.push(patch.seriesId);
    }
    if (patch.title !== undefined) {
      cols.push('title');
      vals.push(patch.title);
    }
    if (patch.description !== undefined) {
      cols.push('description');
      vals.push(patch.description);
    }
    if (patch.imageName !== undefined) {
      cols.push('image_name');
      vals.push(patch.imageName);
    }
    if (patch.addTime !== undefined) {
      cols.push('add_time');
      vals.push(patch.addTime);
    }
    if (patch.authors !== undefined) {
      cols.push('authors');
      vals.push(JSON.stringify(patch.authors));
    }
    if (patch.category !== undefined) {
      cols.push('category_id');
      vals.push(patch.category.id);
      cols.push('category_title');
      vals.push(patch.category.title);
    }
    if (patch.subCategory !== undefined) {
      cols.push('sub_category_id');
      vals.push(patch.subCategory.id);
      cols.push('sub_category_title');
      vals.push(patch.subCategory.title);
    }
    if (patch.tags !== undefined) {
      cols.push('tags');
      vals.push(JSON.stringify(patch.tags));
    }
    if (patch.works !== undefined) {
      cols.push('works');
      vals.push(JSON.stringify(patch.works));
    }
    if (patch.actors !== undefined) {
      cols.push('actors');
      vals.push(JSON.stringify(patch.actors));
    }
    if (patch.isAids !== undefined) {
      cols.push('is_aids');
      vals.push(patch.isAids ? 1 : 0);
    }
    if (patch.price !== undefined) {
      cols.push('price');
      vals.push(patch.price);
    }
    if (patch.totalPicture !== undefined) {
      cols.push('total_picture');
      vals.push(patch.totalPicture);
    }
    if (patch.liked !== undefined) {
      cols.push('liked');
      vals.push(patch.liked ? 1 : 0);
    }
    if (patch.isFavorite !== undefined) {
      cols.push('is_favorite');
      vals.push(patch.isFavorite ? 1 : 0);
    }
    if (patch.purchased !== undefined) {
      cols.push('purchased');
      vals.push(patch.purchased);
    }
    let fetchedAt = patch.fetchedAt !== undefined ? patch.fetchedAt
      : (existing !== null ? existing.fetchedAt : 0);
    if (patch.fetchedAt !== undefined) {
      cols.push('fetched_at');
      vals.push(patch.fetchedAt);
    }
    if (patch.totalViews !== undefined) {
      cols.push('total_views');
      vals.push(AlbumDao.fetchedValue(patch.totalViews, fetchedAt));
    }
    if (patch.likes !== undefined) {
      cols.push('likes');
      vals.push(AlbumDao.fetchedValue(patch.likes, fetchedAt));
    }
    if (patch.commentTotal !== undefined) {
      cols.push('comment_total');
      vals.push(AlbumDao.fetchedValue(patch.commentTotal, fetchedAt));
    }
    if (patch.related !== undefined) {
      cols.push('related');
      vals.push(AlbumDao.fetchedValue(JSON.stringify(patch.related), fetchedAt));
    }
    if (patch.commentPage !== undefined) {
      cols.push('comment_page');
      vals.push(patch.commentPage);
    }
    if (patch.commentFetchedAt !== undefined) {
      cols.push('comment_fetched_at');
      vals.push(patch.commentFetchedAt);
    }
    let marks: string[] = [];
    let updates: string[] = [];
    for (let col of cols) {
      marks.push('?');
      if (col !== 'id') updates.push(`${col} = excluded.${col}`);
    }
    this.db.executeSync(
      `INSERT INTO ${TABLE_ALBUM} (${cols.join(', ')}) VALUES (${marks.join(', ')})
       ON CONFLICT(id) DO UPDATE SET ${updates.join(', ')}`, vals);
  }

  /** 章节目录整体替换（只有详情接口给了 series 时才调用） */
  private replaceChapters(albumId: number, chapters: ComicChapter[]): void {
    this.db.executeSync(`DELETE FROM ${TABLE_CHAPTER} WHERE album_id = ?`, [albumId]);
    for (let ch of chapters) {
      this.db.executeSync(
        `INSERT INTO ${TABLE_CHAPTER} (album_id, photo_id, id, title, sort)
         VALUES (?, ?, ?, ?, ?)`,
        [albumId, ch.photoId, ch.id, ch.title, ch.sort]);
    }
  }

  /**
   * 本地字段是否该重建：
   * - 只有骨架（连标题都没有）说明从未拿到完整字段，立即补；
   * - 其余按「刷新内容·漫画字段」间隔，-1 恒到期、0 每次都重建、MAX 不自动。
   */
  private static fieldsDue(album: ComicAlbum): boolean {
    if (AlbumDao.fieldTtlMs < 0) return true;
    if (album.title === '') return true;
    let lastAt = AlbumDao.instance?.readFieldsAt(album.id) ?? 0;
    return lastAt <= 0 || Date.now() - lastAt >= AlbumDao.fieldTtlMs;
  }

  /** 字段上次重建时间存在 pref 表，随配置保留、不随「清理缓存」删除 */
  private readFieldsAt(albumId: number): number {
    let rs = this.db.querySqlSync(
      `SELECT pref_value FROM ${TABLE_PREF} WHERE pref_key = ?`, [AlbumDao.fieldsAtKey(albumId)]);
    try {
      if (!rs.goToFirstRow()) return 0;
      return Number(rs.getString(rs.getColumnIndex('pref_value'))) || 0;
    } finally {
      rs.close();
    }
  }

  private static markFieldsAt(albumId: number, at: number): void {
    let dao = AlbumDao.instance;
    if (dao === null) return;
    dao.db.executeSync(
      `INSERT INTO ${TABLE_PREF} (pref_key, pref_value) VALUES (?, ?)
       ON CONFLICT(pref_key) DO UPDATE SET pref_value = excluded.pref_value`,
      [AlbumDao.fieldsAtKey(albumId), `${at}`]);
  }

  private static fieldsAtKey(albumId: number): string {
    return `album_fields_at_${albumId}`;
  }

  /**
   * 从联网 patch 里只留下「即时生效」的部分：
   * - imageName：封面换版的版本标识（封面图是否重下由 ComicLibrary 按间隔决定）
   * - chapters：章节目录，新增章节属于本地没有的内容，不等字段间隔
   */
  private static refreshOnlyPatch(patch: ComicAlbumPatch): ComicAlbumPatch {
    let result: ComicAlbumPatch = {} as ComicAlbumPatch;
    if (patch.imageName !== undefined) result.imageName = patch.imageName;
    if (patch.chapters !== undefined) result.chapters = patch.chapters;
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
