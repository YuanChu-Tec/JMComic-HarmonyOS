import { relationalStore } from '@kit.ArkData';
import { AppDatabase, TABLE_READ_STATE } from './AppDatabase';

/**
 * 阅读状态表（read_state）：章节已读标记 + 章节内页码
 *
 * 一行 = (漫画, 章节)。字段含义：
 * - page_index / total：读到第几页，-1 表示没有页码记录（清位置只清这一项）
 * - tick：最后一次与这章交互的时间；取最大者即「最后阅读章节」（清位置时保留，清阅读记录时整行删除）
 * - is_read / read_at：章节是否已读完、什么时候读的（清位置时保留，清阅读记录时整行删除）
 */
export class ProgressDao {
  private static instance: ProgressDao | null = null;
  private db: relationalStore.RdbStore;

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  static async getInstance(): Promise<ProgressDao> {
    if (ProgressDao.instance === null) {
      ProgressDao.instance = new ProgressDao(await AppDatabase.getInstance());
    }
    return ProgressDao.instance;
  }

  /** 标记章节已读（同时刷新 tick，使其成为最后阅读章节） */
  markRead(albumId: number, chapterId: string): void {
    let now = Date.now();
    this.db.executeSync(
      `INSERT INTO ${TABLE_READ_STATE}
         (album_id, chapter_id, page_index, total, tick, is_read, read_at)
       VALUES (?, ?, -1, 0, ?, 1, ?)
       ON CONFLICT(album_id, chapter_id) DO UPDATE SET
         is_read = 1,
         read_at = excluded.read_at,
         tick    = excluded.tick`,
      [albumId, chapterId, now, now]);
  }

  isRead(albumId: number, chapterId: string): boolean {
    let rs = this.db.querySqlSync(
      `SELECT 1 FROM ${TABLE_READ_STATE}
       WHERE album_id = ? AND chapter_id = ? AND is_read = 1`, [albumId, chapterId]);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  /** 章节已读时间，未读返回 0 */
  readAt(albumId: number, chapterId: string): number {
    let rs = this.db.querySqlSync(
      `SELECT read_at FROM ${TABLE_READ_STATE}
       WHERE album_id = ? AND chapter_id = ? AND is_read = 1`, [albumId, chapterId]);
    try {
      return rs.goToFirstRow() ? rs.getLong(rs.getColumnIndex('read_at')) : 0;
    } finally {
      rs.close();
    }
  }

  /** 最后阅读章节（最近一次有交互的章节），无记录返回空串 */
  lastChapter(albumId: number): string {
    let rs = this.db.querySqlSync(
      `SELECT chapter_id FROM ${TABLE_READ_STATE}
       WHERE album_id = ? AND tick > 0 ORDER BY tick DESC LIMIT 1`, [albumId]);
    try {
      return rs.goToFirstRow() ? rs.getString(rs.getColumnIndex('chapter_id')) : '';
    } finally {
      rs.close();
    }
  }

  /** 保存章节内页码，不动已读标记 */
  savePosition(albumId: number, chapterId: string, pageIndex: number, total: number): void {
    this.db.executeSync(
      `INSERT INTO ${TABLE_READ_STATE}
         (album_id, chapter_id, page_index, total, tick, is_read, read_at)
       VALUES (?, ?, ?, ?, ?, 0, 0)
       ON CONFLICT(album_id, chapter_id) DO UPDATE SET
         page_index = excluded.page_index,
         total      = excluded.total,
         tick       = excluded.tick`,
      [albumId, chapterId, pageIndex, total, Date.now()]);
  }

  /** 章节内页码，无记录或已清除返回 -1 */
  position(albumId: number, chapterId: string): number {
    let rs = this.db.querySqlSync(
      `SELECT page_index FROM ${TABLE_READ_STATE}
       WHERE album_id = ? AND chapter_id = ? AND page_index >= 0`, [albumId, chapterId]);
    try {
      return rs.goToFirstRow() ? rs.getLong(rs.getColumnIndex('page_index')) : -1;
    } finally {
      rs.close();
    }
  }

  /**
   * 清除某本漫画的页码记录。
   * tick 不动：再打开仍落到最后阅读的那一章，只是从第 1 页开始。
   */
  clearPositions(albumId: number): void {
    this.db.executeSync(
      `UPDATE ${TABLE_READ_STATE} SET page_index = -1, total = 0 WHERE album_id = ?`,
      [albumId]);
  }

  /** 清除全部漫画的页码记录，返回有页码记录的漫画数；最后阅读章节与已读标记保留 */
  clearAllPositions(): number {
    let count = this.countAlbumsWithPosition();
    this.db.executeSync(
      `UPDATE ${TABLE_READ_STATE} SET page_index = -1, total = 0`);
    return count;
  }

  /**
   * 清除全部阅读记录：已读标记、最后阅读章节与阅读位置一并清掉（整表 DELETE）。
   * 与 clearAllPositions 的分工：那个只清页码、保留已读与最后章节，这个全清。
   * @returns 有阅读记录的漫画数
   */
  clearAllReadHistory(): number {
    let count = this.countAlbumsWithHistory();
    this.db.executeSync(`DELETE FROM ${TABLE_READ_STATE}`);
    return count;
  }

  /**
   * 某本漫画各章最后一次交互时间（tick 与已读时间取大），供清理阅读缓存判断新旧。
   * 清位置只清页码，tick / read_at 都保留，缓存新旧判定不受影响；
   * 清阅读记录会删掉整行，该漫画的缓存新旧判定退回目录写入时间。
   */
  lastActivityOfAlbum(albumId: number): Map<string, number> {
    let rs = this.db.querySqlSync(
      `SELECT chapter_id, tick, read_at FROM ${TABLE_READ_STATE} WHERE album_id = ?`, [albumId]);
    let map: Map<string, number> = new Map<string, number>();
    try {
      let idIdx = rs.getColumnIndex('chapter_id');
      let tickIdx = rs.getColumnIndex('tick');
      let readIdx = rs.getColumnIndex('read_at');
      while (rs.goToNextRow()) {
        let id = rs.getString(idIdx);
        map.set(id, Math.max(rs.getLong(tickIdx), rs.getLong(readIdx)));
      }
    } finally {
      rs.close();
    }
    return map;
  }

  /** 有页码记录的漫画数（清位置之后不再计入，所以按 page_index 而不是 tick 判） */
  private countAlbumsWithPosition(): number {
    let rs = this.db.querySqlSync(
      `SELECT COUNT(DISTINCT album_id) AS n FROM ${TABLE_READ_STATE} WHERE page_index >= 0`);
    try {
      return rs.goToFirstRow() ? rs.getLong(rs.getColumnIndex('n')) : 0;
    } finally {
      rs.close();
    }
  }

  /** 有阅读历史的漫画数（清历史之后行不再计入，所以按整表 distinct album 判） */
  private countAlbumsWithHistory(): number {
    let rs = this.db.querySqlSync(
      `SELECT COUNT(DISTINCT album_id) AS n FROM ${TABLE_READ_STATE}`);
    try {
      return rs.goToFirstRow() ? rs.getLong(rs.getColumnIndex('n')) : 0;
    } finally {
      rs.close();
    }
  }
}
