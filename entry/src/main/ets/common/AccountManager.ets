import { AccountDao, AccountRecord } from '../storage/AccountDao';
import { SettingDao } from '../storage/SettingDao';
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

/** pref 表里记录当前活跃账号登录名的键 */
const KEY_ACTIVE = 'active_username';

/** pref 表里记录最近一次成功会话快照的键（冷启动据此先点亮登录态） */
const KEY_SESSION = 'active_session';

/** pref 表里记录是否允许冷启动自动登录的键（'0' 关闭，缺省开启） */
const KEY_AUTO_LOGIN = 'auto_login';

/**
 * 会话快照：UserSession 的可序列化字段
 *
 * 只用于冷启动渲染（头像/昵称/等级/金币先在屏上），服务端有效性由随后的静默登录复验。
 */
interface SessionSnapshot {
  uid: string;
  username: string;
  email: string;
  photo: string;
  coin: number;
  level: number;
  levelName: string;
  albumFavorites: number;
  albumFavoritesMax: number;
  sessionToken: string;
}

/**
 * 多账号管理器
 *
 * 职责：
 * - 维护已保存账号列表（account 表，顺序由 sort 列决定）
 * - 跟踪当前活跃账号（pref 表的 active_username），冷启动自动登录取其凭据
 * - 切换账号 = 用保存的凭据重新走 /login（服务端身份由 AVS cookie 决定，单全局 cookie，
 *   因此同一时刻只有一个会话有效，旧会话被覆盖）
 * - 退出登录 = 移除当前账号并清空会话（其余已保存账号保留，供下次登录后快速切换）
 */
export class AccountManager {
  private static instance: AccountManager | null = null;
  private dao: AccountDao | null = null;
  private settings: SettingDao | null = null;
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
   * 初始化：从 account 表与 pref 表读回数据（幂等，重复调用仅首次生效）
   */
  async init(): Promise<void> {
    if (this.dao !== null) return;
    this.dao = await AccountDao.getInstance();
    this.settings = await SettingDao.getInstance();
    this.accounts = this.dao.list().map((r: AccountRecord) => this.toSaved(r));
    this.activeUsername = this.settings.get(KEY_ACTIVE, '');
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
   * 是否允许冷启动自动登录（缺省开启，与加开关之前的行为一致）
   *
   * 关掉后既不恢复会话快照、也不静默登录，启动停在未登录；凭据仍留在账号表里，
   * 账号管理页照样能一键切换。
   */
  isAutoLoginEnabled(): boolean {
    if (this.settings === null) return true;
    return this.settings.get(KEY_AUTO_LOGIN, '1') !== '0';
  }

  /** 切换自动登录偏好（关闭时顺带清掉会话快照，否则下次启动仍会先亮起） */
  setAutoLoginEnabled(enabled: boolean): void {
    if (this.settings === null) return;
    this.settings.set(KEY_AUTO_LOGIN, enabled ? '1' : '0');
    if (!enabled) {
      this.clearSessionSnapshot();
    }
  }

  /**
   * 登录成功后登记账号：更新或插入列表项、置为活跃账号
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
    // 快照只服务于冷启动：没记住密码、或用户关了自动登录，都不该留
    if (savePassword && password && this.isAutoLoginEnabled()) {
      this.saveSessionSnapshot(session);
    } else {
      this.clearSessionSnapshot();
    }
    AppStorage.setOrCreate('activeUsername', username);
  }

  /**
   * 读回最近一次会话快照（同步，冷启动在首帧前调用）
   *
   * 返回的会话未经服务端校验：调用方应先点亮界面，再后台静默登录复验。
   */
  loadSessionSnapshot(): UserSession | null {
    if (this.settings === null) return null;
    let raw = this.settings.get(KEY_SESSION, '');
    if (!raw) return null;
    try {
      let snapshot = JSON.parse(raw) as SessionSnapshot;
      if (!snapshot.username) return null;
      return this.toSession(snapshot);
    } catch (err) {
      console.warn('[AccountManager] loadSessionSnapshot parse error:', JSON.stringify(err));
      return null;
    }
  }

  /** 清掉会话快照（退出登录、密码未被记住、静默复验失败时调用） */
  clearSessionSnapshot(): void {
    if (this.settings === null) return;
    this.settings.remove(KEY_SESSION);
  }

  private saveSessionSnapshot(session: UserSession): void {
    if (this.settings === null) return;
    let snapshot: SessionSnapshot = {
      uid: session.uid,
      username: session.username,
      email: session.email,
      photo: session.photo,
      coin: session.coin,
      level: session.level,
      levelName: session.levelName,
      albumFavorites: session.albumFavorites,
      albumFavoritesMax: session.albumFavoritesMax,
      sessionToken: session.sessionToken,
    };
    this.settings.set(KEY_SESSION, JSON.stringify(snapshot));
  }

  private toSession(snapshot: SessionSnapshot): UserSession {
    let session = new UserSession();
    session.uid = snapshot.uid;
    session.username = snapshot.username;
    session.email = snapshot.email;
    session.photo = snapshot.photo;
    session.coin = snapshot.coin;
    session.level = snapshot.level;
    session.levelName = snapshot.levelName;
    session.albumFavorites = snapshot.albumFavorites;
    session.albumFavoritesMax = snapshot.albumFavoritesMax;
    session.sessionToken = snapshot.sessionToken;
    session.isLoggedIn = true;
    return session;
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
    // 快照一并清掉，否则下次启动会先亮起刚退出的账号
    this.clearSessionSnapshot();
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

  /** 账号列表整表替换 + 活跃账号写 pref（量极小，逐条对比意义不大） */
  private persist(): void {
    if (this.dao === null || this.settings === null) return;
    this.dao.replaceAll(this.accounts.map((a: SavedAccount) => this.toRecord(a)));
    this.settings.set(KEY_ACTIVE, this.activeUsername);
  }

  private toRecord(a: SavedAccount): AccountRecord {
    return {
      username: a.username,
      password: a.password,
      nickname: a.nickname,
      photo: a.photo,
      level: a.level,
      levelName: a.levelName,
    } as AccountRecord;
  }

  private toSaved(r: AccountRecord): SavedAccount {
    return {
      username: r.username,
      password: r.password,
      nickname: r.nickname,
      photo: r.photo,
      level: r.level,
      levelName: r.levelName,
    } as SavedAccount;
  }

  /** 清理与登录用户绑定的缓存（收藏列表），避免切换/退出账号后残留他人数据 */
  private async clearUserScopedCache(): Promise<void> {
    let cache = await CacheManager.getInstance();
    cache.clearUserScopedCache();
  }
}
