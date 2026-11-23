import { relationalStore } from '@kit.ArkData';
import { AppDatabase, TABLE_PAGE_CACHE } from './AppDatabase';

/** 一页列表缓存（首页分类、搜索、收藏共用一种形状） */
export interface CachedPage {
  data: string;
  total: number;
  extra: string;
  timestamp: number;
}

/**
 * 列表分页缓存的持久化入口（DAO）
 *
 * 一行 = 一页列表响应，cache_key 形如 cat_{分类}_{排序}_p{页}、search_{词}_p{页}、fav_{夹}_p{页}。
 * 属于可重建数据：进 AppDatabase.CACHE_TABLES，随「清理缓存」整表清空。
 * TTL 判断留在 CacheManager，本类只负责存取。
 */
export class PageCacheDao {
  private static instance: PageCacheDao | null = null;
  private db: relationalStore.RdbStore;

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  static async getInstance(): Promise<PageCacheDao> {
    if (PageCacheDao.instance === null) {
      PageCacheDao.instance = new PageCacheDao(await AppDatabase.getInstance());
    }
    return PageCacheDao.instance;
  }

  save(key: string, data: string, total: number, extra: string): void {
    this.db.executeSync(
      `INSERT INTO ${TABLE_PAGE_CACHE} (cache_key, data, total, extra, timestamp)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(cache_key) DO UPDATE SET
         data      = excluded.data,
         total     = excluded.total,
         extra     = excluded.extra,
         timestamp = excluded.timestamp`,
      [key, data, total, extra, Date.now()]);
  }

  get(key: string): CachedPage | null {
    let rs = this.db.querySqlSync(
      `SELECT data, total, extra, timestamp FROM ${TABLE_PAGE_CACHE} WHERE cache_key = ?`, [key]);
    try {
      if (!rs.goToFirstRow()) return null;
      return {
        data: rs.getString(rs.getColumnIndex('data')),
        total: rs.getLong(rs.getColumnIndex('total')),
        extra: rs.getString(rs.getColumnIndex('extra')),
        timestamp: rs.getLong(rs.getColumnIndex('timestamp')),
      } as CachedPage;
    } finally {
      rs.close();
    }
  }

  /** 某前缀下已缓存的页码，升序（切尾、转数字、排序都交给 SQL） */
  pageNumbers(prefix: string): number[] {
    let rs = this.db.querySqlSync(
      `SELECT CAST(substr(cache_key, ?) AS INTEGER) AS page_no
       FROM ${TABLE_PAGE_CACHE}
       WHERE substr(cache_key, 1, ?) = ?
       ORDER BY page_no`,
      [prefix.length + 1, prefix.length, prefix]);
    let pages: number[] = [];
    try {
      let idx = rs.getColumnIndex('page_no');
      while (rs.goToNextRow()) {
        pages.push(rs.getLong(idx));
      }
    } finally {
      rs.close();
    }
    return pages;
  }

  /** 删除某前缀下的全部分页（用 substr 精确匹配，不把 _ 当通配符） */
  removePrefix(prefix: string): void {
    this.db.executeSync(
      `DELETE FROM ${TABLE_PAGE_CACHE} WHERE substr(cache_key, 1, ?) = ?`,
      [prefix.length, prefix]);
  }
}
