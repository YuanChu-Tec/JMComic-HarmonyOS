import { relationalStore } from '@kit.ArkData';
import { AppDatabase, TABLE_ACCOUNT } from './AppDatabase';

/** 账号表一行（明文密码，与 SavedAccount 一一对应） */
export interface AccountRecord {
  username: string;
  password: string;
  nickname: string;
  photo: string;
  level: number;
  levelName: string;
}

/**
 * 已保存账号表（account）
 *
 * 顺序由 sort 列显式维护：整表替换时按数组下标写入，读出时 ORDER BY sort，
 * 保证「账号列表顺序」与 UI 看到的顺序一致。
 */
export class AccountDao {
  private static instance: AccountDao | null = null;
  private db: relationalStore.RdbStore;

  private constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  static async getInstance(): Promise<AccountDao> {
    if (AccountDao.instance === null) {
      AccountDao.instance = new AccountDao(await AppDatabase.getInstance());
    }
    return AccountDao.instance;
  }

  list(): AccountRecord[] {
    let rs = this.db.querySqlSync(
      `SELECT username, password, nickname, photo, level, level_name
       FROM ${TABLE_ACCOUNT} ORDER BY sort`);
    let accounts: AccountRecord[] = [];
    try {
      let iUser = rs.getColumnIndex('username');
      let iPass = rs.getColumnIndex('password');
      let iNick = rs.getColumnIndex('nickname');
      let iPhoto = rs.getColumnIndex('photo');
      let iLevel = rs.getColumnIndex('level');
      let iLevelName = rs.getColumnIndex('level_name');
      while (rs.goToNextRow()) {
        accounts.push({
          username: rs.getString(iUser),
          password: rs.getString(iPass),
          nickname: rs.getString(iNick),
          photo: rs.getString(iPhoto),
          level: rs.getLong(iLevel),
          levelName: rs.getString(iLevelName),
        } as AccountRecord);
      }
    } finally {
      rs.close();
    }
    return accounts;
  }

  /** 整表替换（账号量极小，避免增量同步的排序维护） */
  replaceAll(accounts: AccountRecord[]): void {
    this.db.beginTransaction();
    try {
      this.db.executeSync(`DELETE FROM ${TABLE_ACCOUNT}`);
      for (let i = 0; i < accounts.length; i++) {
        let a = accounts[i];
        this.db.executeSync(
          `INSERT INTO ${TABLE_ACCOUNT}
             (username, password, nickname, photo, level, level_name, sort)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
          [a.username, a.password, a.nickname, a.photo, a.level, a.levelName, i]);
      }
      this.db.commit();
    } catch (e) {
      this.db.rollBack();
      throw e as Error;
    }
  }
}
