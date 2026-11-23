import { relationalStore } from '@kit.ArkData';
import { Feed, FeedSection } from '../models/AlbumFeed';
import { AppDatabase, TABLE_FEED, TABLE_FEED_ITEM, TABLE_FEED_SECTION } from './AppDatabase';

/**
 * 列表顺序的持久化入口（DAO）
 *
 * 一个列表 = 一行 feed + 若干行 feed_section（带 sort）+ 若干行 feed_item（带 sort）。
 * 读写风格与 AlbumDao 一致：读用 querySqlSync，写用事务内 executeSync。
 *
 * 写入整列表替换：先删子表再插。列表顺序属于可重建数据，
 * 清缓存时由 AppDatabase.CACHE_TABLES 整表 DELETE。
 */
export class FeedDao {
  private static instance: FeedDao | null = null;
  private db: relationalStore.RdbStore;

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  static async getInstance(): Promise<FeedDao> {
    if (FeedDao.instance === null) {
      let db = await AppDatabase.getInstance();
      FeedDao.instance = new FeedDao(db);
    }
    return FeedDao.instance;
  }

  /** 读一个列表：feed 一行 + 分区与成员，未命中返回 null */
  get(key: string): Feed | null {
    let rs = this.db.querySqlSync(
      `SELECT total, updated_at FROM ${TABLE_FEED} WHERE feed_key = ?`, [key]);
    try {
      if (!rs.goToFirstRow()) return null;
      return {
        key: key,
        sections: this.readSections(key),
        total: rs.getLong(rs.getColumnIndex('total')),
        updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
      } as Feed;
    } finally {
      rs.close();
    }
  }

  /**
   * 一次查询带出分区与成员，按 (section.sort, item.sort) 分组。
   * LEFT JOIN 保留空分区（0 本的收藏夹也要出现在夹子清单里）。
   */
  private readSections(feedKey: string): FeedSection[] {
    let rs = this.db.querySqlSync(
      `SELECT s.section_key AS section_key, s.title AS title, i.album_id AS album_id
       FROM ${TABLE_FEED_SECTION} s
       LEFT JOIN ${TABLE_FEED_ITEM} i
         ON i.feed_key = s.feed_key AND i.section_key = s.section_key
       WHERE s.feed_key = ?
       ORDER BY s.sort, i.sort`, [feedKey]);
    let sections: FeedSection[] = [];
    let byKey: Map<string, FeedSection> = new Map<string, FeedSection>();
    try {
      while (rs.goToNextRow()) {
        let sectionKey = rs.getString(rs.getColumnIndex('section_key'));
        let section = byKey.get(sectionKey);
        if (section === undefined) {
          section = {
            key: sectionKey,
            title: rs.getString(rs.getColumnIndex('title')),
            ids: [],
          } as FeedSection;
          sections.push(section);
          byKey.set(sectionKey, section);
        }
        let albumId = rs.getLong(rs.getColumnIndex('album_id'));
        if (albumId > 0) section.ids.push(albumId);
      }
    } finally {
      rs.close();
    }
    return sections;
  }

  /** 写入：整列表替换，updatedAt 在落库时刷新 */
  save(feed: Feed): void {
    this.db.beginTransaction();
    try {
      this.db.executeSync(
        `INSERT INTO ${TABLE_FEED} (feed_key, total, updated_at) VALUES (?, ?, ?)
         ON CONFLICT(feed_key) DO UPDATE SET
           total      = excluded.total,
           updated_at = excluded.updated_at`,
        [feed.key, feed.total, Date.now()]);
      this.db.executeSync(`DELETE FROM ${TABLE_FEED_SECTION} WHERE feed_key = ?`, [feed.key]);
      this.db.executeSync(`DELETE FROM ${TABLE_FEED_ITEM} WHERE feed_key = ?`, [feed.key]);
      for (let i = 0; i < feed.sections.length; i++) {
        let section = feed.sections[i];
        this.db.executeSync(
          `INSERT INTO ${TABLE_FEED_SECTION} (feed_key, section_key, title, sort)
           VALUES (?, ?, ?, ?)`,
          [feed.key, section.key, section.title, i]);
        for (let j = 0; j < section.ids.length; j++) {
          this.db.executeSync(
            `INSERT INTO ${TABLE_FEED_ITEM} (feed_key, section_key, album_id, sort)
             VALUES (?, ?, ?, ?)`,
            [feed.key, section.key, section.ids[j], j]);
        }
      }
      this.db.commit();
    } catch (e) {
      this.db.rollBack();
      throw e as Error;
    }
  }

  /** 删除一个列表（三张表一起删） */
  remove(key: string): void {
    this.db.beginTransaction();
    try {
      this.db.executeSync(`DELETE FROM ${TABLE_FEED_ITEM} WHERE feed_key = ?`, [key]);
      this.db.executeSync(`DELETE FROM ${TABLE_FEED_SECTION} WHERE feed_key = ?`, [key]);
      this.db.executeSync(`DELETE FROM ${TABLE_FEED} WHERE feed_key = ?`, [key]);
      this.db.commit();
    } catch (e) {
      this.db.rollBack();
      throw e as Error;
    }
  }

  /** 已有的列表标识，最近写入的在前 */
  getAllKeys(): string[] {
    let rs = this.db.querySqlSync(`SELECT feed_key FROM ${TABLE_FEED} ORDER BY updated_at DESC`);
    let keys: string[] = [];
    try {
      while (rs.goToNextRow()) {
        keys.push(rs.getString(rs.getColumnIndex('feed_key')));
      }
    } finally {
      rs.close();
    }
    return keys;
  }

  /** 清空全部列表顺序，返回清除的列表数 */
  clearAll(): number {
    let count = this.getAllKeys().length;
    this.db.beginTransaction();
    try {
      this.db.executeSync(`DELETE FROM ${TABLE_FEED_ITEM}`);
      this.db.executeSync(`DELETE FROM ${TABLE_FEED_SECTION}`);
      this.db.executeSync(`DELETE FROM ${TABLE_FEED}`);
      this.db.commit();
    } catch (e) {
      this.db.rollBack();
      throw e as Error;
    }
    console.info(`[FeedDao] cleared ${count} feeds`);
    return count;
  }

  /**
   * 以 prefix 开头的列表标识（分页恢复用：more:xxx:p1、p2…）。
   * 用 substr 比较而非 LIKE，键里的 `_` 不会被当成通配符。
   */
  keysWithPrefix(prefix: string): string[] {
    let rs = this.db.querySqlSync(
      `SELECT feed_key FROM ${TABLE_FEED} WHERE substr(feed_key, 1, ?) = ?
       ORDER BY updated_at DESC`, [prefix.length, prefix]);
    let keys: string[] = [];
    try {
      while (rs.goToNextRow()) {
        keys.push(rs.getString(rs.getColumnIndex('feed_key')));
      }
    } finally {
      rs.close();
    }
    return keys;
  }

  /** 删除以 prefix 开头的列表（本地数据被外部改动后作废，如删除浏览记录） */
  removePrefix(prefix: string): void {
    let keys = this.keysWithPrefix(prefix);
    for (let key of keys) {
      this.remove(key);
    }
  }

  /** 一本漫画出现在哪些列表（收藏夹归属反查），最近写入的在前 */
  feedKeysOf(albumId: number): string[] {
    let rs = this.db.querySqlSync(
      `SELECT DISTINCT i.feed_key AS feed_key
       FROM ${TABLE_FEED_ITEM} i
       JOIN ${TABLE_FEED} f ON f.feed_key = i.feed_key
       WHERE i.album_id = ?
       ORDER BY f.updated_at DESC`, [albumId]);
    let keys: string[] = [];
    try {
      while (rs.goToNextRow()) {
        keys.push(rs.getString(rs.getColumnIndex('feed_key')));
      }
    } finally {
      rs.close();
    }
    return keys;
  }
}
