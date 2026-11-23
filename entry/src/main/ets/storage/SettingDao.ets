import { relationalStore } from '@kit.ArkData';
import { AppDatabase, TABLE_PREF } from './AppDatabase';

/**
 * 应用设置的持久化入口（DAO）
 *
 * 一张 pref 表承载全部键值：主题、阅读模式、缓存保留天数、导出标记、活跃账号等。
 * pref_value 统一存字符串，调用方自行转换，语义与原来的 Preferences 读写一致。
 * 属配置类数据，不在 AppDatabase.CACHE_TABLES 里，不随「清理缓存」删除。
 */
export class SettingDao {
  private static instance: SettingDao | null = null;
  private db: relationalStore.RdbStore;

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  static async getInstance(): Promise<SettingDao> {
    if (SettingDao.instance === null) {
      SettingDao.instance = new SettingDao(await AppDatabase.getInstance());
    }
    return SettingDao.instance;
  }

  get(key: string, defVal: string = ''): string {
    let rs = this.db.querySqlSync(
      `SELECT pref_value FROM ${TABLE_PREF} WHERE pref_key = ?`, [key]);
    try {
      if (!rs.goToFirstRow()) return defVal;
      return rs.getString(rs.getColumnIndex('pref_value'));
    } finally {
      rs.close();
    }
  }

  /** 数字型设置：缺失或非法时返回 defVal */
  getNumber(key: string, defVal: number): number {
    let raw = this.get(key, '');
    if (!raw) return defVal;
    let n = Number(raw);
    return Number.isNaN(n) ? defVal : n;
  }

  set(key: string, value: string): void {
    this.db.executeSync(
      `INSERT INTO ${TABLE_PREF} (pref_key, pref_value) VALUES (?, ?)
       ON CONFLICT(pref_key) DO UPDATE SET pref_value = excluded.pref_value`,
      [key, value]);
  }

  remove(key: string): void {
    this.db.executeSync(`DELETE FROM ${TABLE_PREF} WHERE pref_key = ?`, [key]);
  }
}
