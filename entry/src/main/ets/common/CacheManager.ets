import { CachedPage, PageCacheDao } from '../storage/PageCacheDao';
import { SettingDao } from '../storage/SettingDao';
import { ProgressDao } from '../storage/ProgressDao';
import { AlbumDao } from '../storage/AlbumDao';
import { FavoriteFolderItem } from '../models/dto/ApiDto';

/**
 * 本地缓存与轻量状态门面
 *
 * 数据一律落 RDB（不再使用 Preferences）：
 * - 列表分页响应 → page_cache（PageCacheDao，cat_/search_/fav_ 前缀 + 页码，带 TTL）
 * - 开关与偏好   → pref（SettingDao，键值与旧 Preferences 保持一致）
 * - 阅读进度     → read_state（ProgressDao）
 *
 * 章节图片元数据不在这里：只落 ComicLibrary 的 meta.json（与 PNG 同目录、同生命周期）。
 *
 * 对外方法保持同步签名：store 在 getInstance() 时就绪，之后全部走 querySqlSync/executeSync。
 * 调用方必须先 await getInstance() 再调用其它方法。
 */
export class CacheManager {
  private static instance: CacheManager | null = null;

  /**
   * 列表（feed 表）的新鲜度：首页、更多页、分类、搜索、收藏共用。
   * 本地有数据但超过这个时间才联网刷新，未过期直接用本地。
   * 时长由设置页「列表刷新间隔」控制，0 分钟表示不自动刷新（只用本地）。
   */
  static readonly DEFAULT_FEED_TTL_MINUTES: number = 60;
  /**
   * 当前生效的刷新间隔（分钟）。页面里的过期判定是同步的
   * （Date.now() - updatedAt > ttl），因此实例化时读到静态字段，
   * 设置页保存后直接改这个字段，判定点立刻按新值走。
   */
  private static feedTtlMinutes: number = CacheManager.DEFAULT_FEED_TTL_MINUTES;
  private static MAX_SEARCH_HISTORY = 9999;

  private settings: SettingDao;
  private pages: PageCacheDao;
  private progress: ProgressDao;

  private constructor(settings: SettingDao, pages: PageCacheDao, progress: ProgressDao) {
    this.settings = settings;
    this.pages = pages;
    this.progress = progress;
  }

  static async getInstance(): Promise<CacheManager> {
    if (CacheManager.instance === null) {
      let settings = await SettingDao.getInstance();
      let pages = await PageCacheDao.getInstance();
      let progress = await ProgressDao.getInstance();
      CacheManager.feedTtlMinutes = settings.getNumber('pref_feed_refresh_minutes',
        CacheManager.DEFAULT_FEED_TTL_MINUTES);
      for (let kind of CacheManager.REFRESH_KINDS) {
        CacheManager.autoRefresh.set(kind, settings.getNumber(`pref_auto_refresh_${kind}`, 1) !== 0);
      }
      // 字段/封面两个维度由 DAO 与图片仓库在同步路径上读取，这里推一份静态副本过去
      AlbumDao.refreshFields = CacheManager.isAutoRefresh(CacheManager.CONTENT_FIELD);
      AlbumDao.refreshCovers = CacheManager.isAutoRefresh(CacheManager.CONTENT_COVER);
      CacheManager.instance = new CacheManager(settings, pages, progress);
    }
    return CacheManager.instance;
  }

  /** 列表过期判定用的 TTL：0 分钟表示永不自动刷新 */
  static feedTtlMs(): number {
    return CacheManager.feedTtlMinutes <= 0
      ? Number.MAX_SAFE_INTEGER
      : CacheManager.feedTtlMinutes * 60 * 1000;
  }

  // ─── 通用方法 ───

  private put(key: string, value: string): void {
    this.settings.set(key, value);
  }

  private getString(key: string, defVal: string = ''): string {
    return this.settings.get(key, defVal);
  }

  private putObject<T>(key: string, obj: T): void {
    this.put(key, JSON.stringify(obj));
  }

  private getObject<T>(key: string, defVal: T | null = null): T | null {
    let raw = this.getString(key, '');
    if (!raw) return defVal;
    try {
      return JSON.parse(raw) as T;
    } catch {
      return defVal;
    }
  }

  // ─── 搜索历史 ───

  getSearchHistory(): string[] {
    return this.getObject<string[]>('search_history') || [];
  }

  addSearchHistory(keyword: string): void {
    let history = this.getSearchHistory();
    history = history.filter(k => k !== keyword);
    history.unshift(keyword);
    if (history.length > CacheManager.MAX_SEARCH_HISTORY) {
      history = history.slice(0, CacheManager.MAX_SEARCH_HISTORY);
    }
    this.putObject('search_history', history);
  }

  clearSearchHistory(): void {
    this.putObject('search_history', [] as string[]);
  }

  // ─── 评论列表缓存（整页 JSON，评论暂不入实体表）───

  private static commentPrefix(kind: string, ownerId: string): string {
    return `cmt_${kind}_${ownerId}_p`;
  }

  saveCommentPage(kind: string, ownerId: string, page: number, list: string, total: number): void {
    this.pages.save(`${CacheManager.commentPrefix(kind, ownerId)}${page}`, list, total, '');
  }

  loadCommentPage(kind: string, ownerId: string, page: number): CachedPage | null {
    let entry = this.pages.get(`${CacheManager.commentPrefix(kind, ownerId)}${page}`);
    if (!entry) return null;
    if (Date.now() - entry.timestamp > CacheManager.feedTtlMsOf(CacheManager.REFRESH_FORUM)) {
      return null;
    }
    return entry;
  }

  getCommentPages(kind: string, ownerId: string): number[] {
    return this.pages.pageNumbers(CacheManager.commentPrefix(kind, ownerId));
  }

  /** 发表/回复/点赞后作废，下次读取重新联网 */
  clearCommentPages(kind: string, ownerId: string): void {
    this.pages.removePrefix(CacheManager.commentPrefix(kind, ownerId));
  }

  // ─── 收藏夹清单（不属于任何一本漫画，单独存一条）───

  /** 按账号隔离：多账号下收藏夹清单不能互相覆盖 */
  saveFavoriteFolders(username: string, folders: FavoriteFolderItem[]): void {
    this.putObject(`favorite_folders_${username}`, folders);
  }

  loadFavoriteFolders(username: string): FavoriteFolderItem[] {
    return this.getObject<FavoriteFolderItem[]>(`favorite_folders_${username}`) || [];
  }

  /**
   * 清理旧版按 fav_ 前缀存的收藏分页缓存（历史残留）。
   * 收藏列表已迁到 feed 表且键里带用户名，切换账号天然隔离；
   * 这里顺手清掉老版本的 page_cache 行，避免升级后留垃圾。
   */
  clearUserScopedCache(): void {
    this.pages.removePrefix('fav_');
  }

  // ─── 用户偏好 ───

  saveLastCategory(category: string): void {
    this.put('pref_category', category);
  }

  getLastCategory(): string {
    return this.getString('pref_category', '0');
  }

  saveLastOrder(order: string): void {
    this.put('pref_order', order);
  }

  getLastOrder(): string {
    return this.getString('pref_order', 'mr');
  }

  // ─── 刷新间隔 ───

  /** 刷新间隔（分钟）：0 表示不自动刷新，只用本地 */
  saveFeedRefreshMinutes(minutes: number): void {
    CacheManager.feedTtlMinutes = minutes;
    this.put('pref_feed_refresh_minutes', `${minutes}`);
  }

  getFeedRefreshMinutes(): number {
    return CacheManager.feedTtlMinutes;
  }

  // ─── 自动刷新范围（按内容种类开关）───

  /** 内容种类：设置页的开关与页面过期判定共用这些键，也是 pref 键后缀 */
  static readonly REFRESH_HOME: string = 'home';
  static readonly REFRESH_CATEGORY: string = 'category';
  /** 搜索结果快照（键 search:{词}:p{页}）；关掉后同一关键词永远用本地结果 */
  static readonly REFRESH_SEARCH: string = 'search';
  static readonly REFRESH_DETAIL: string = 'detail';
  static readonly REFRESH_PROFILE: string = 'profile';
  static readonly REFRESH_FORUM: string = 'forum';

  /**
   * 刷新内容维度：刷新时重建哪些产物。
   * 与上面的「刷新范围」正交——范围决定要不要联网，维度决定联网结果落到哪一层。
   */
  static readonly CONTENT_FIELD: string = 'content_field';
  static readonly CONTENT_COVER: string = 'content_cover';
  static readonly CONTENT_IMAGE: string = 'content_image';

  /** 两组开关共用一套 pref 键：Map 里没有记录时按开启处理 */
  static readonly REFRESH_KINDS: string[] =
    ['home', 'category', 'search', 'detail', 'profile', 'forum',
      'content_field', 'content_cover', 'content_image'];

  /**
   * 各类内容是否允许自动刷新。页面过期判定是同步的，
   * 所以除了 pref 之外再留一份静态内存副本，设置页改动后立即生效。
   * Map 里没有记录时按开启处理（首次启动、getInstance 之前都安全）。
   */
  private static autoRefresh: Map<string, boolean> = new Map<string, boolean>();

  static isAutoRefresh(kind: string): boolean {
    return CacheManager.autoRefresh.get(kind) ?? true;
  }

  saveAutoRefresh(kind: string, enabled: boolean): void {
    CacheManager.autoRefresh.set(kind, enabled);
    this.put(`pref_auto_refresh_${kind}`, enabled ? '1' : '0');
    // DAO 的字段写入是同步路径，开关改完立刻推过去
    if (kind === CacheManager.CONTENT_FIELD) AlbumDao.refreshFields = enabled;
    if (kind === CacheManager.CONTENT_COVER) AlbumDao.refreshCovers = enabled;
  }

  /** 某类内容的过期 TTL：关掉自动刷新等价于「永不过期」，只用本地 */
  static feedTtlMsOf(kind: string): number {
    return CacheManager.isAutoRefresh(kind) ? CacheManager.feedTtlMs() : Number.MAX_SAFE_INTEGER;
  }

  // ─── 图片仓库自动清理策略 ───

  /** 阅读缓存保留天数：0 表示不自动清理，默认 7 天 */
  saveReadCacheDays(days: number): void {
    this.put('pref_read_cache_days', `${days}`);
  }

  getReadCacheDays(): number {
    return this.settings.getNumber('pref_read_cache_days', 7);
  }

  /** 已导出内容保留天数：0 表示不自动清理，默认关闭 */
  saveExportedDays(days: number): void {
    this.put('pref_exported_days', `${days}`);
  }

  getExportedDays(): number {
    return this.settings.getNumber('pref_exported_days', 0);
  }

  // ─── 下载任务 ───

  saveDownloadTasks(tasks: string): void {
    this.put('download_tasks', tasks);
  }

  loadDownloadTasks(): string {
    return this.getString('download_tasks', '[]');
  }

  // ─── 下载功能引导 ───

  /** 首次使用下载功能时是否已展示过引导（后台下载 + 手动到下载管理页导出保存的流程说明） */
  getDownloadGuideShown(): boolean {
    return this.getString('download_guide_shown') === '1';
  }

  setDownloadGuideShown(): void {
    this.put('download_guide_shown', '1');
  }

  // ─── 专辑导出状态 ───

  /**
   * 专辑导出时间，0 表示未导出。
   * 清理规则按这个时间判断「导出后保留 N 天」，所以存的是时间戳而不是 '1'；
   * 旧版留下的 '1' 读到后补写成当前时间，给清理一次宽限，避免升级后立刻被删。
   */
  getAlbumExportedAt(albumId: number): number {
    let raw = this.getString(`exported_${albumId}`);
    if (!raw) return 0;
    let ts = Number(raw);
    if (ts > 1) return ts;
    let now = Date.now();
    this.put(`exported_${albumId}`, `${now}`);
    return now;
  }

  /** 专辑是否已导出过压缩包（手动导出成功后标记；向专辑新增章节任务时重置为未导出） */
  isAlbumExported(albumId: number): boolean {
    return this.getAlbumExportedAt(albumId) > 0;
  }

  /**
   * 标记 / 取消导出。取消时直接删键，清理规则随之失效，
   * 不会出现「界面显示未导出、清理仍按旧导出时间删文件」。
   */
  setAlbumExported(albumId: number, exported: boolean): void {
    if (exported) {
      this.put(`exported_${albumId}`, `${Date.now()}`);
    } else {
      this.settings.remove(`exported_${albumId}`);
    }
  }

  // ─── 导出设置 ───

  /** 导出成功后是否自动删除本地下载文件（仅保留下载记录），默认关闭 */
  isAutoDeleteAfterExport(): boolean {
    return this.getString('auto_delete_after_export') === '1';
  }

  setAutoDeleteAfterExport(enabled: boolean): void {
    this.put('auto_delete_after_export', enabled ? '1' : '0');
  }

  // ─── 版本更新忽略 ───

  /** 用户选择「忽略此版本」后记录的版本号，等于它时不再弹更新提示 */
  getSkipUpdateVersion(): string {
    return this.getString('skip_update_version');
  }

  setSkipUpdateVersion(version: string): void {
    this.put('skip_update_version', version);
  }

  // ─── 阅读模式（竖向滚动 / 横向翻页方向） ───
  // 取值：'scroll' 竖向滚动(下)；'paged_ltr' 横向从左往右(西漫)；'paged_rtl' 横向从右往左(日漫)

  /** 读取阅读模式，默认 'scroll'（竖向连续滚动） */
  getReaderMode(): string {
    let v = this.getString('reader_mode');
    if (v === 'paged_ltr' || v === 'paged_rtl' || v === 'scroll') {
      return v;
    }
    return 'scroll';
  }

  setReaderMode(mode: string): void {
    this.put('reader_mode', mode);
  }

  // ─── 阅读历史（已读章节标记） ───

  markChapterRead(albumId: number, chapterId: string): void {
    this.progress.markRead(albumId, chapterId);
  }

  isChapterRead(albumId: number, chapterId: string): boolean {
    return this.progress.isRead(albumId, chapterId);
  }

  getLastReadChapterId(albumId: number): string {
    return this.progress.lastChapter(albumId);
  }

  getChapterReadTime(albumId: number, chapterId: string): number {
    return this.progress.readAt(albumId, chapterId);
  }

  // ─── 阅读位置（章节内图片索引） ───

  /** 保存某章节的阅读位置（图片索引），同时使其成为最后阅读章节 */
  saveReadPosition(albumId: number, chapterId: string, pageIndex: number, total: number): void {
    this.progress.savePosition(albumId, chapterId, pageIndex, total);
  }

  /** 读取某章节的阅读位置，无记录返回 -1 */
  getReadPosition(albumId: number, chapterId: string): number {
    return this.progress.position(albumId, chapterId);
  }

  /** 清空某本漫画的章节页码（已读标记与最后阅读章节保留） */
  clearReadPositions(albumId: number): void {
    this.progress.clearPositions(albumId);
  }

  /**
   * 清空全部漫画的章节页码
   * 已读标记与「最后阅读章节」保留：章节仍显示"已读"，
   * 再打开漫画会进入上次那一章，但停在第 1 页。
   * @returns 清除的漫画数量
   */
  clearAllReadPositions(): number {
    return this.progress.clearAllPositions();
  }
}
