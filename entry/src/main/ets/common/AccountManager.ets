import { preferences } from '@kit.ArkData';
import { UserSession } from '../models/Album';
import { ApiService } from '../network/ApiService';
import { CacheManager } from './CacheManager';

/** 已保存账号（多账号列表项） */
export interface SavedAccount {
  username: string;      // 登录名，列表内唯一键
  password: string;      // 明文密码；空串表示未保存密码（无法快速切换）
  nickname: string;      // 昵称（登录接口返回的 username）
  photo: string;         // 头像文件名（空串使用默认头像）
  level: number;
  levelName: string;
}

/** 活跃账号的登录凭据 */
export interface ActiveCredentials {
  username: string;
  password: string;
}

const PREF_NAME = 'JMComicUser';
const KEY_ACCOUNTS = 'accounts';        // SavedAccount[] JSON 串
const KEY_ACTIVE = 'active_username';   // 当前登录账号的登录名
// 旧版单账号键：与活跃账号保持同步写入，回滚旧版本时自动登录仍可用
const KEY_LEGACY_USERNAME = 'username';
const KEY_LEGACY_PASSWORD = 'password';
const KEY_LEGACY_SAVE = 'savePassword';

/**
 * 多账号管理器
 *
 * 职责：
 * - 维护已保存账号列表（持久化在 preferences 'JMComicUser' 的 accounts 键）
 * - 跟踪当前活跃账号，冷启动自动登录取其凭据
 * - 切换账号 = 用保存的凭据重新走 /login（服务端身份由 AVS cookie 决定，单全局 cookie，
 *   因此同一时刻只有一个会话有效，旧会话被覆盖）
 * - 退出登录 = 移除当前账号并清空会话（其余已保存账号保留，供下次登录后快速切换）
 *
 * 旧版本单账号数据迁移：首次 init 时若不存在 accounts 键但存在旧 username/password 键，
 * 则迁移为列表首项并置为活跃账号。
 */
export class AccountManager {
  private static instance: AccountManager | null = null;
  private prefs: preferences.Preferences | null = null;
  private accounts: SavedAccount[] = [];
  private activeUsername: string = '';
  private apiService: ApiService = ApiService.getInstance();

  private constructor() {
  }

  static getInstance(): AccountManager {
    if (AccountManager.instance === null) {
      AccountManager.instance = new AccountManager();
    }
    return AccountManager.instance;
  }

  /**
   * 初始化：读取持久化数据并执行旧版单账号迁移（幂等，重复调用仅首次生效）
   */
  async init(): Promise<void> {
    if (this.prefs) return;
    this.prefs = await preferences.getPreferences(getContext(), PREF_NAME);

    let raw = this.prefs.getSync(KEY_ACCOUNTS, '') as string;
    if (raw) {
      try {
        this.accounts = JSON.parse(raw) as SavedAccount[];
      } catch {
        this.accounts = [];
      }
      this.activeUsername = this.prefs.getSync(KEY_ACTIVE, '') as string;
    } else {
      // 旧版单账号迁移
      let legacyUser = this.prefs.getSync(KEY_LEGACY_USERNAME, '') as string;
      let legacyPass = this.prefs.getSync(KEY_LEGACY_PASSWORD, '') as string;
      if (legacyUser && legacyPass) {
        let migrated: SavedAccount = {
          username: legacyUser,
          password: legacyPass,
          nickname: legacyUser,
          photo: '',
          level: 0,
          levelName: ''
        };
        this.accounts = [migrated];
        this.activeUsername = legacyUser;
        this.persist();
        console.info('[AccountManager] 已迁移旧版单账号数据');
      }
    }
    AppStorage.setOrCreate('activeUsername', this.activeUsername);
  }

  /** 已保存账号列表（副本，供 UI @State 使用） */
  getAccounts(): SavedAccount[] {
    return this.accounts.slice();
  }

  /** 当前活跃账号（未登录或无匹配时返回 null） */
  getActiveAccount(): SavedAccount | null {
    return this.findByUsername(this.activeUsername);
  }

  /**
   * 活跃账号的登录凭据（未保存密码时返回 null，冷启动自动登录用）
   */
  getActiveCredentials(): ActiveCredentials | null {
    let active = this.getActiveAccount();
    if (!active || !active.password) return null;
    let creds: ActiveCredentials = { username: active.username, password: active.password };
    return creds;
  }

  /**
   * 登录成功后登记账号：更新或插入列表项、置为活跃账号、同步旧版键
   *
   * @param username 登录名
   * @param password 登录用密码
   * @param session 登录接口返回的会话
   * @param savePassword 是否保存密码（未保存则该账号不可快速切换）
   */
  async recordLogin(username: string, password: string, session: UserSession, savePassword: boolean): Promise<void> {
    let existing = this.findByUsername(username);
    let entry: SavedAccount = existing ?? {
      username: username,
      password: '',
      nickname: username,
      photo: '',
      level: 0,
      levelName: ''
    };
    entry.password = savePassword ? password : '';
    entry.nickname = session.username || username;
    entry.photo = session.photo;
    entry.level = session.level;
    entry.levelName = session.levelName;
    if (!existing) {
      this.accounts.push(entry);
    }
    this.activeUsername = username;
    this.persist();

    let savedPass = savePassword ? password : '';
    await this.syncLegacy(username, savedPass, savePassword);
    AppStorage.setOrCreate('activeUsername', username);
  }

  /**
   * 切换到已保存账号：用保存的凭据重新登录（成功后该账号变为活跃账号）
   *
   * @throws 账号不存在 / 未保存密码 / 登录失败（网络或密码错误）
   */
  async switchTo(username: string): Promise<UserSession> {
    let entry = this.findByUsername(username);
    if (!entry) throw new Error('账号不存在');
    if (!entry.password) throw new Error('该账号未保存密码，无法快速切换');

    let session = await this.apiService.login(entry.username, entry.password);
    await this.recordLogin(entry.username, entry.password, session, true);
    await this.clearUserScopedCache();
    return session;
  }

  /**
   * 退出登录：移除当前账号并清空会话（其余已保存账号保留）
   */
  async logoutCurrent(): Promise<void> {
    this.accounts = this.accounts.filter(a => a.username !== this.activeUsername);
    this.activeUsername = '';
    this.persist();

    // 清空旧版单账号键，避免冷启动自动登录复活已退出的账号
    if (this.prefs) {
      this.prefs.putSync(KEY_LEGACY_USERNAME, '');
      this.prefs.putSync(KEY_LEGACY_PASSWORD, '');
      this.prefs.putSync(KEY_LEGACY_SAVE, true);
      this.prefs.flushSync();
    }
    this.apiService.logout();
    await this.clearUserScopedCache();
    AppStorage.setOrCreate('activeUsername', '');
  }

  private findByUsername(username: string): SavedAccount | null {
    for (let account of this.accounts) {
      if (account.username === username) return account;
    }
    return null;
  }

  private persist(): void {
    if (!this.prefs) return;
    this.prefs.putSync(KEY_ACCOUNTS, JSON.stringify(this.accounts));
    this.prefs.putSync(KEY_ACTIVE, this.activeUsername);
    this.prefs.flushSync();
  }

  /** 旧版单账号键与活跃账号保持同步（回滚旧版本时自动登录仍可用） */
  private async syncLegacy(username: string, password: string, savePassword: boolean): Promise<void> {
    if (!this.prefs) return;
    this.prefs.putSync(KEY_LEGACY_USERNAME, username);
    this.prefs.putSync(KEY_LEGACY_PASSWORD, savePassword ? password : '');
    this.prefs.putSync(KEY_LEGACY_SAVE, savePassword);
    this.prefs.flushSync();
  }

  /** 清理与登录用户绑定的缓存（收藏列表），避免切换/退出账号后残留他人数据 */
  private async clearUserScopedCache(): Promise<void> {
    let cache = await CacheManager.getInstance();
    cache.clearUserScopedCache();
  }
}
