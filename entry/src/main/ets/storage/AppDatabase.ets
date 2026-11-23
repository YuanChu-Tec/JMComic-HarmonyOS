import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 表名常量，DAO 统一引用，避免手写字符串拼错 */
export const TABLE_ALBUM: string = 'album';
export const TABLE_CHAPTER: string = 'chapter';
export const TABLE_COMMENT: string = 'comment';
export const TABLE_FEED: string = 'feed';
export const TABLE_FEED_SECTION: string = 'feed_section';
export const TABLE_FEED_ITEM: string = 'feed_item';
export const TABLE_PREF: string = 'pref';
export const TABLE_PAGE_CACHE: string = 'page_cache';
export const TABLE_READ_STATE: string = 'read_state';
export const TABLE_ACCOUNT: string = 'account';

const DB_NAME: string = 'jmcomic.db';
/**
 * 结构版本。DDL 全部 IF NOT EXISTS 且每次开库重放（见 open），
 * 应用未发布，改表结构直接改 DDL 即可，不做版本迁移。
 */
const DB_VERSION: number = 1;

/**
 * 全局唯一的 RdbStore
 *
 * 设计要点：
 * - 表是唯一数据源：UI 只读表，网络响应只写表，页面写完再读一次
 * - 一部漫画的固有数据落在 album / chapter
 * - 章节图片元数据只有一份：ComicLibrary 的 meta.json（与 PNG 同目录、同生命周期）
 * - 列表顺序（首页、分类、搜索、收藏）落在 feed / feed_section / feed_item
 * - 图片二进制不入库，路径由 ComicLibrary.getImagePath() 用 (albumId, photoId, idx) 现推
 */
export class AppDatabase {
  private static task: Promise<relationalStore.RdbStore> | null = null;

  /** 随「清理缓存」一起清空的表（album 里的统计列单独置空） */
  static readonly CACHE_TABLES: string[] = [
    TABLE_COMMENT,
    TABLE_FEED_ITEM,
    TABLE_FEED_SECTION,
    TABLE_FEED,
    TABLE_PAGE_CACHE,
  ];

  static getInstance(): Promise<relationalStore.RdbStore> {
    if (AppDatabase.task === null) {
      let task = AppDatabase.open();
      AppDatabase.task = task;
      // 开库失败就清掉缓存，下次调用重试；否则一次失败会让所有读写永久不可用
      task.catch((err: Error) => {
        console.error('[AppDatabase] open failed:', JSON.stringify(err));
        AppDatabase.task = null;
      });
    }
    return AppDatabase.task;
  }

  private static async open(): Promise<relationalStore.RdbStore> {
    // 启动预热时窗口内容还没加载，getContext() 是 undefined，优先用 EntryAbility 存的实例
    let abilityCtx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    let ctx: common.UIAbilityContext =
      abilityCtx !== undefined ? abilityCtx : getContext() as common.UIAbilityContext;
    console.info(`[AppDatabase] open start, db=${DB_NAME}, filesDir=${ctx?.filesDir}`);
    let config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    };
    let store = await relationalStore.getRdbStore(ctx, config);
    let old: number = store.version;
    console.info(`[AppDatabase] store ready, version=${old}`);
    // 建表幂等，每次开库重放：改表结构直接改 DDL，不用升版本，也不怕旧库缺表
    await AppDatabase.createSchema(store);
    if (old < DB_VERSION) {
      store.version = DB_VERSION;
      console.info(`[AppDatabase] schema ${old} -> ${DB_VERSION}`);
    }
    return store;
  }

  // ─── 执行与查询 ───

  static async run(sql: string, args?: relationalStore.ValueType[]): Promise<void> {
    let store = await AppDatabase.getInstance();
    await store.executeSql(sql, args);
  }

  static async query(sql: string, args?: relationalStore.ValueType[]): Promise<relationalStore.ResultSet> {
    let store = await AppDatabase.getInstance();
    return store.querySql(sql, args);
  }

  /**
   * 事务：work 内不要发起并发任务，所有写入走同一个 store 连接。
   * beginTransaction 是同步调用，commit / rollBack 也是。
   */
  static async transaction(work: () => Promise<void>): Promise<void> {
    let store = await AppDatabase.getInstance();
    store.beginTransaction();
    try {
      await work();
      store.commit();
    } catch (e) {
      store.rollBack();
      throw e as Error;
    }
  }

  // ─── 清理 ───

  /** 清空可重建的缓存表（评论、列表快照、分页） */
  static async clearCacheTables(): Promise<void> {
    for (let table of AppDatabase.CACHE_TABLES) {
      await AppDatabase.run(`DELETE FROM ${table}`);
    }
  }

  /**
   * 清空 album 上的缓存列：统计与评论游标置空，用户态（liked / is_favorite / purchased）
   * 和固有字段一律不动，否则清完缓存收藏状态就丢了。
   */
  static async clearAlbumCache(): Promise<void> {
    await AppDatabase.run(
      'UPDATE album SET total_views = NULL, likes = NULL, comment_total = NULL, ' +
        'related = NULL, fetched_at = 0, comment_page = 0, comment_fetched_at = 0');
  }

  // ─── 建表 ───

  private static async createSchema(store: relationalStore.RdbStore): Promise<void> {
    for (let sql of AppDatabase.DDL) {
      await store.executeSql(sql);
    }
  }

  /**
   * 全部建表语句，幂等，每次开库都跑一遍。
   * album 的缓存列允许 NULL（表示从未拉取），不能用 DEFAULT ''。
   */
  private static readonly DDL: string[] = [
    `CREATE TABLE IF NOT EXISTS ${TABLE_ALBUM} (
      id                 INTEGER PRIMARY KEY,
      series_id          TEXT    NOT NULL DEFAULT '',
      title              TEXT    NOT NULL DEFAULT '',
      description        TEXT    NOT NULL DEFAULT '',
      image_name         TEXT    NOT NULL DEFAULT '',
      add_time           TEXT    NOT NULL DEFAULT '',
      authors            TEXT    NOT NULL DEFAULT '[]',
      category_id        INTEGER NOT NULL DEFAULT 0,
      category_title     TEXT    NOT NULL DEFAULT '',
      sub_category_id    INTEGER NOT NULL DEFAULT 0,
      sub_category_title TEXT    NOT NULL DEFAULT '',
      tags               TEXT    NOT NULL DEFAULT '[]',
      works              TEXT    NOT NULL DEFAULT '[]',
      actors             TEXT    NOT NULL DEFAULT '[]',
      is_aids            INTEGER NOT NULL DEFAULT 0,
      price              TEXT    NOT NULL DEFAULT '',
      total_picture      TEXT    NOT NULL DEFAULT '',
      updated_at         INTEGER NOT NULL DEFAULT 0,
      liked              INTEGER NOT NULL DEFAULT 0,
      is_favorite        INTEGER NOT NULL DEFAULT 0,
      purchased          TEXT    NOT NULL DEFAULT '',
      total_views        TEXT,
      likes              TEXT,
      comment_total      INTEGER,
      related            TEXT,
      fetched_at         INTEGER NOT NULL DEFAULT 0,
      comment_page       INTEGER NOT NULL DEFAULT 0,
      comment_fetched_at INTEGER NOT NULL DEFAULT 0
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_CHAPTER} (
      album_id INTEGER NOT NULL,
      photo_id TEXT    NOT NULL,
      id       INTEGER NOT NULL DEFAULT 0,
      title    TEXT    NOT NULL DEFAULT '',
      sort     INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (album_id, photo_id)
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_COMMENT} (
      album_id       INTEGER NOT NULL,
      cid            TEXT    NOT NULL,
      parent_cid     TEXT    NOT NULL DEFAULT '',
      uid            TEXT    NOT NULL DEFAULT '',
      user_name      TEXT    NOT NULL DEFAULT '',
      user_level     TEXT    NOT NULL DEFAULT '',
      level_title    TEXT    NOT NULL DEFAULT '',
      posted_at      TEXT    NOT NULL DEFAULT '',
      content        TEXT    NOT NULL DEFAULT '',
      head_url       TEXT    NOT NULL DEFAULT '',
      like_count     INTEGER NOT NULL DEFAULT 0,
      link_book_id   TEXT    NOT NULL DEFAULT '',
      link_book_name TEXT    NOT NULL DEFAULT '',
      sort           INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (album_id, cid)
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_FEED} (
      feed_key   TEXT    PRIMARY KEY,
      total      INTEGER NOT NULL DEFAULT -1,
      updated_at INTEGER NOT NULL DEFAULT 0
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_FEED_SECTION} (
      feed_key    TEXT    NOT NULL,
      section_key TEXT    NOT NULL,
      title       TEXT    NOT NULL DEFAULT '',
      sort        INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (feed_key, section_key)
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_FEED_ITEM} (
      feed_key    TEXT    NOT NULL,
      section_key TEXT    NOT NULL,
      album_id    INTEGER NOT NULL,
      sort        INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (feed_key, section_key, album_id)
    )`,

    `CREATE INDEX IF NOT EXISTS idx_chapter_order ON ${TABLE_CHAPTER} (album_id, sort)`,
    `CREATE INDEX IF NOT EXISTS idx_comment_parent ON ${TABLE_COMMENT} (album_id, parent_cid, sort)`,
    `CREATE INDEX IF NOT EXISTS idx_feed_item_album ON ${TABLE_FEED_ITEM} (album_id)`,
    `CREATE TABLE IF NOT EXISTS ${TABLE_PREF} (
      pref_key   TEXT PRIMARY KEY,
      pref_value TEXT NOT NULL DEFAULT ''
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_PAGE_CACHE} (
      cache_key TEXT    PRIMARY KEY,
      data      TEXT    NOT NULL DEFAULT '',
      total     INTEGER NOT NULL DEFAULT 0,
      extra     TEXT    NOT NULL DEFAULT '',
      timestamp INTEGER NOT NULL DEFAULT 0
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_READ_STATE} (
      album_id   INTEGER NOT NULL,
      chapter_id TEXT    NOT NULL,
      page_index INTEGER NOT NULL DEFAULT -1,
      total      INTEGER NOT NULL DEFAULT 0,
      tick       INTEGER NOT NULL DEFAULT 0,
      is_read    INTEGER NOT NULL DEFAULT 0,
      read_at    INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (album_id, chapter_id)
    )`,

    `CREATE TABLE IF NOT EXISTS ${TABLE_ACCOUNT} (
      username   TEXT    PRIMARY KEY,
      password   TEXT    NOT NULL DEFAULT '',
      nickname   TEXT    NOT NULL DEFAULT '',
      photo      TEXT    NOT NULL DEFAULT '',
      level      INTEGER NOT NULL DEFAULT 0,
      level_name TEXT    NOT NULL DEFAULT '',
      sort       INTEGER NOT NULL DEFAULT 0
    )`,

    `CREATE INDEX IF NOT EXISTS idx_page_cache_ts ON ${TABLE_PAGE_CACHE} (timestamp)`,
    `CREATE INDEX IF NOT EXISTS idx_read_state_album ON ${TABLE_READ_STATE} (album_id, tick)`,
    `CREATE INDEX IF NOT EXISTS idx_album_favorite ON ${TABLE_ALBUM} (is_favorite)`,
    `CREATE INDEX IF NOT EXISTS idx_album_updated ON ${TABLE_ALBUM} (updated_at)`,
  ];
}
