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
   * 页面（首页 / 更多 / 分类 / 搜索 / 详情 / 收藏 / 论坛）始终联网刷新：
   * 本地数据只作首屏占位，进入页面或切回 Tab 就拉一次最新，不做 TTL 节流。
   */
  static readonly PAGE_TTL_MS: number = -1;
  /**
   * 「立即刷新」的间隔哨兵值：每次都重建，用于内容项。
   * 不能与「不自动」共用 0，因此单独取 -1（与「导出后立即删除」的哨兵约定一致）。
   */
  static readonly IMMEDIATE_REFRESH_MINUTES: number = -1;
  /** 内容项未单独设置时的默认重建间隔（分钟） */
  static readonly DEFAULT_CONTENT_TTL_MINUTES: number = 60;
  /**
   * 刷新内容 3 项的重建间隔：只放设置过的 kind，缺省即默认值。
   * 静态内存副本，供同步的过期判定直接读。
   */
  private static contentTtlOverrides: Map<string, number> = new Map<string, number>();
  /** 内容项设置的 pref 键前缀（后缀是 content_*） */
  private static readonly CONTENT_OVERRIDE_PREFIX: string = 'pref_content_refresh_minutes_';
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
      // 内容项设置：没有 pref 行就用默认重建间隔
      CacheManager.contentTtlOverrides.clear();
      for (let kind of CacheManager.CONTENT_KINDS) {
        let raw = settings.get(`${CacheManager.CONTENT_OVERRIDE_PREFIX}${kind}`, '');
        if (raw === '') continue;
        let minutes = Number(raw);
        if (!Number.isNaN(minutes)) CacheManager.contentTtlOverrides.set(kind, minutes);
      }
      // 字段/封面由 DAO 与图片仓库在同步路径上读取，这里推一份静态 TTL 过去
      AlbumDao.fieldTtlMs = CacheManager.contentTtlMsOf(CacheManager.CONTENT_FIELD);
      AlbumDao.coverTtlMs = CacheManager.contentTtlMsOf(CacheManager.CONTENT_COVER);
      CacheManager.instance = new CacheManager(settings, pages, progress);
    }
    return CacheManager.instance;
  }

  /** 分钟数换算成过期判定 TTL：-1 = 立即刷新（任何落库时间都算过期）；0 = 永不自动刷新 */
  private static ttlMsOf(minutes: number): number {
    if (minutes === CacheManager.IMMEDIATE_REFRESH_MINUTES) {
      return -1;
    }
    return minutes <= 0
      ? Number.MAX_SAFE_INTEGER
      : minutes * 60 * 1000;
  }

  /** 某内容项生效的重建间隔（分钟）：有设置用设置值，否则用默认值 */
  static contentMinutesOf(kind: string): number {
    let override = CacheManager.contentTtlOverrides.get(kind);
    return override === undefined ? CacheManager.DEFAULT_CONTENT_TTL_MINUTES : override;
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
    if (Date.now() - entry.timestamp > CacheManager.feedTtlMs()) {
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

  // ─── 刷新内容间隔 ───

  /** 内容项重建间隔（分钟）：-1 每次都重建，0 表示不自动重建 */
  saveContentRefreshMinutesOf(kind: string, minutes: number): void {
    let key = `${CacheManager.CONTENT_OVERRIDE_PREFIX}${kind}`;
    CacheManager.contentTtlOverrides.set(kind, minutes);
    this.put(key, `${minutes}`);
    this.syncContentTtl(kind);
  }

  /** 内容项当前生效的重建间隔（分钟），未设置时返回默认 60 分钟 */
  getContentRefreshMinutesOf(kind: string): number {
    return CacheManager.contentMinutesOf(kind);
  }

  /** 把某项的 TTL 推给同步判定方（字段/封面在 DAO 与图片仓库侧读取） */
  private syncContentTtl(kind: string): void {
    let ttl = CacheManager.contentTtlMsOf(kind);
    if (kind === CacheManager.CONTENT_FIELD) AlbumDao.fieldTtlMs = ttl;
    if (kind === CacheManager.CONTENT_COVER) AlbumDao.coverTtlMs = ttl;
  }

  // ─── 内容类别 ───

  /** 刷新内容维度：联网拿到数据后重建哪一层，三项各自有间隔 */
  static readonly CONTENT_FIELD: string = 'content_field';
  static readonly CONTENT_COVER: string = 'content_cover';
  static readonly CONTENT_IMAGE: string = 'content_image';

  /** 可单独设置间隔的内容项 */
  static readonly CONTENT_KINDS: string[] =
    ['content_field', 'content_cover', 'content_image'];

  /** 页面过期判定：始终联网刷新（本地只作首屏占位） */
  static feedTtlMs(): number {
    return CacheManager.PAGE_TTL_MS;
  }

  /** 内容项的重建节流（ms）：-1 每次都重建，MAX 表示不自动重建 */
  static contentTtlMsOf(kind: string): number {
    return CacheManager.ttlMsOf(CacheManager.contentMinutesOf(kind));
  }

  /**
   * 某层产物距上次重建是否已到间隔。
   * lastAt 为 0（从未重建）按到期处理；设为「不自动」则永远不到期。
   */
  static contentDue(kind: string, lastAt: number): boolean {
    let ttl = CacheManager.contentTtlMsOf(kind);
    if (ttl === Number.MAX_SAFE_INTEGER) return false;
    if (ttl < 0) return true;
    return lastAt <= 0 || Date.now() - lastAt >= ttl;
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
  // 取值：'scroll' 竖向滚动(下)；'paged_ltr' 横向从左往右(国漫)；'paged_rtl' 横向从右往左(日漫)

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

  /**
   * 清空全部阅读记录：已读标记、最后阅读章节与阅读位置一起清掉。
   * 之后章节不再显示"已读"，打开漫画从第一章第 1 页开始；
   * 阅读缓存的活跃时间判定退回用目录写入时间。
   * @returns 清除的漫画数量
   */
  clearAllReadHistory(): number {
    return this.progress.clearAllReadHistory();
  }
}
