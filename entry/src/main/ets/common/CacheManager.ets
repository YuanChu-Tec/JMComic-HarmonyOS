import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/**
 * 本地缓存管理器
 * 基于 Preferences 实现数据持久化，减少网络请求
 *
 * 缓存策略：
 * - 首页列表：按 category+order 分 key 缓存，带 TTL 过期
 * - 搜索历史：最近 20 条关键词
 * - 收藏列表：按 folderId 分 key 缓存
 * - 用户偏好：分类、排序选择
 * - 下载任务：序列化保存
 */
export class CacheManager {
  private static PREF_NAME = 'JMComicCache';
  /** 所有记录过阅读位置的漫画 ID 列表（Preferences 不支持枚举 key，需自行维护索引） */
  private static KEY_POS_ALBUMS = 'pos_albums';
  private static TTL_CATEGORY = 30 * 60 * 1000; // 30 分钟
  private static TTL_FAVORITE = 10 * 60 * 1000; // 10 分钟
  private static TTL_SEARCH_RESULT = 30 * 60 * 1000; // 30 分钟
  private static MAX_SEARCH_HISTORY = 9999;

  private static instance: CacheManager | null = null;
  private prefs: preferences.Preferences | null = null;

  private constructor() {
  }

  /**
   * 获取实例
   * @param context 非 UI 上下文（如 UIAbility）调用时需显式传入，
   *                页面组件中可省略，内部用 getContext()
   */
  static async getInstance(context?: Context): Promise<CacheManager> {
    if (CacheManager.instance === null) {
      CacheManager.instance = new CacheManager();
    }
    if (CacheManager.instance.prefs === null) {
      CacheManager.instance.prefs = await preferences.getPreferences(context ?? getContext(), CacheManager.PREF_NAME);
    }
    return CacheManager.instance;
  }

  // ─── 通用方法 ───

  private put(key: string, value: string): void {
    this.prefs?.putSync(key, value);
    this.prefs?.flushSync();
  }

  private getString(key: string, defVal: string = ''): string {
    return this.prefs?.getSync(key, defVal) as string || defVal;
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

  // ─── 首页分类列表缓存 ───

  saveCategoryList(category: string, order: string, page: number, albums: string, total: number): void {
    let key = `cat_${category}_${order}`;
    let pageKey = `${key}_p${page}`;
    let entry: CachePageEntry = {
      data: albums,
      total: total,
      timestamp: Date.now()
    };
    this.putObject(pageKey, entry);
    let index = this.getObject<number[]>(`${key}_pages`) || [];
    if (!index.includes(page)) {
      index.push(page);
      this.putObject(`${key}_pages`, index);
    }
  }

  loadCategoryList(category: string, order: string, page: number): CachePageEntry | null {
    let key = `cat_${category}_${order}`;
    let pageKey = `${key}_p${page}`;
    let entry = this.getObject<CachePageEntry>(pageKey);
    if (!entry) return null;
    if (Date.now() - entry.timestamp > CacheManager.TTL_CATEGORY) {
      return null;
    }
    return entry;
  }

  getCategoryPages(category: string, order: string): number[] {
    let key = `cat_${category}_${order}`;
    return this.getObject<number[]>(`${key}_pages`) || [];
  }

  clearCategoryCache(category: string, order: string): void {
    let key = `cat_${category}_${order}`;
    let pages = this.getCategoryPages(category, order);
    for (let p of pages) {
      this.prefs?.deleteSync(`${key}_p${p}`);
    }
    this.prefs?.deleteSync(`${key}_pages`);
    this.prefs?.flushSync();
  }

  // ─── 搜索结果缓存 ───

  saveSearchResult(keyword: string, page: number, albums: string, total: number): void {
    let key = `search_${keyword}_p${page}`;
    let entry: CachePageEntry = {
      data: albums,
      total: total,
      timestamp: Date.now()
    };
    this.putObject(key, entry);
  }

  loadSearchResult(keyword: string, page: number): CachePageEntry | null {
    let key = `search_${keyword}_p${page}`;
    let entry = this.getObject<CachePageEntry>(key);
    if (!entry) return null;
    if (Date.now() - entry.timestamp > CacheManager.TTL_SEARCH_RESULT) {
      return null;
    }
    return entry;
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
    this.putObject('search_history', []);
  }

  // ─── 收藏列表缓存 ───

  saveFavoriteList(folderId: string, page: number, albums: string, total: number, folders: string): void {
    let pageKey = `fav_${folderId}_p${page}`;
    let entry: CachePageEntry = {
      data: albums,
      total: total,
      timestamp: Date.now(),
      extra: folders
    };
    this.putObject(pageKey, entry);
    let index = this.getObject<number[]>(`fav_${folderId}_pages`) || [];
    if (!index.includes(page)) {
      index.push(page);
      this.putObject(`fav_${folderId}_pages`, index);
    }
  }

  loadFavoriteList(folderId: string, page: number): CachePageEntry | null {
    let pageKey = `fav_${folderId}_p${page}`;
    let entry = this.getObject<CachePageEntry>(pageKey);
    if (!entry) return null;
    if (Date.now() - entry.timestamp > CacheManager.TTL_FAVORITE) {
      return null;
    }
    return entry;
  }

  getFavoritePages(folderId: string): number[] {
    return this.getObject<number[]>(`fav_${folderId}_pages`) || [];
  }

  clearFavoriteCache(folderId: string): void {
    let pages = this.getFavoritePages(folderId);
    for (let p of pages) {
      this.prefs?.deleteSync(`fav_${folderId}_p${p}`);
    }
    this.prefs?.deleteSync(`fav_${folderId}_pages`);
    this.prefs?.flushSync();
  }

  /**
   * 清理与登录用户绑定的缓存（收藏列表等 fav_ 前缀键）
   * 多账号切换/退出登录时调用，避免展示上一账号的数据
   */
  clearUserScopedCache(): void {
    if (!this.prefs) return;
    let all = this.prefs.getAllSync() as Record<string, preferences.ValueType>;
    for (let key of Object.keys(all)) {
      if (key.startsWith('fav_')) {
        this.prefs.deleteSync(key);
      }
    }
    this.prefs.flushSync();
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

  // ─── 图片仓库自动清理策略 ───

  /** 阅读缓存保留天数：0 表示不自动清理，默认 7 天 */
  saveReadCacheDays(days: number): void {
    this.put('pref_read_cache_days', `${days}`);
  }

  getReadCacheDays(): number {
    return Number(this.getString('pref_read_cache_days', '7'));
  }

  /** 已导出内容保留天数：0 表示不自动清理，默认关闭 */
  saveExportedDays(days: number): void {
    this.put('pref_exported_days', `${days}`);
  }

  getExportedDays(): number {
    return Number(this.getString('pref_exported_days', '0'));
  }

  // ─── 章节图片数据缓存 ───

  /** 章节元数据缓存有效期 24h；过期后重新拉取，避免长期使用旧图片列表/旧 scramble_id */
  private static readonly CHAPTER_DATA_TTL_MS: number = 24 * 60 * 60 * 1000;

  saveChapterData(photoId: string, dataJson: string): void {
    this.put(`chapter_${photoId}`, dataJson);
    this.put(`chapter_${photoId}_ts`, `${Date.now()}`);
  }

  loadChapterData(photoId: string): string | null {
    let ts: number = Number(this.getString(`chapter_${photoId}_ts`, '0'));
    // 旧版本写入的数据没有时间戳，或已过期，都视为未命中并重新请求
    if (ts <= 0 || Date.now() - ts > CacheManager.CHAPTER_DATA_TTL_MS) {
      return null;
    }
    return this.getString(`chapter_${photoId}`) || null;
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

  /** 专辑是否已导出过压缩包（手动导出成功后标记；向专辑新增章节任务时重置为未导出） */
  isAlbumExported(albumId: number): boolean {
    return this.getString(`exported_${albumId}`) === '1';
  }

  setAlbumExported(albumId: number, exported: boolean): void {
    if (exported) {
      this.put(`exported_${albumId}`, '1');
    } else {
      this.prefs?.deleteSync(`exported_${albumId}`);
      this.prefs?.flushSync();
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
    this.put(`read_${albumId}_${chapterId}`, Date.now().toString());
    // 同时更新最后阅读章节（v2：旧 lastread_ 前缀的记录直接作废）
    this.put(`rlast_${albumId}`, chapterId);
    this.trackPosAlbum(albumId);
  }

  isChapterRead(albumId: number, chapterId: string): boolean {
    let val = this.getString(`read_${albumId}_${chapterId}`);
    return val !== '';
  }

  getLastReadChapterId(albumId: number): string {
    return this.getString(`rlast_${albumId}`);
  }

  getChapterReadTime(albumId: number, chapterId: string): number {
    let val = this.getString(`read_${albumId}_${chapterId}`);
    return val ? parseInt(val) : 0;
  }

  // ─── 阅读位置（章节内图片索引） ───

  /**
   * 保存某章节的阅读位置（图片索引）
   * 同时更新"最后阅读章节"，与章节级已读标记保持一致
   */
  saveReadPosition(albumId: number, chapterId: string, pageIndex: number, total: number): void {
    let pos: ReadPosition = { index: pageIndex, total: total, tick: Date.now() };
    this.putObject(`rpos_${albumId}_${chapterId}`, pos);
    // 维护该漫画已记录位置的章节列表，便于整体清空
    let chapters = this.getObject<string[]>(`rplist_${albumId}`) || [];
    if (!chapters.includes(chapterId)) {
      chapters.push(chapterId);
      this.putObject(`rplist_${albumId}`, chapters);
    }
    this.put(`rlast_${albumId}`, chapterId);
    this.trackPosAlbum(albumId);
  }

  /** 读取某章节的阅读位置，无记录返回 -1 */
  getReadPosition(albumId: number, chapterId: string): number {
    let pos = this.getObject<ReadPosition>(`rpos_${albumId}_${chapterId}`);
    return pos && pos.index >= 0 ? pos.index : -1;
  }

  /** 清空某本漫画的全部阅读位置（新键前缀） */
  clearReadPositions(albumId: number): void {
    let chapters = this.getObject<string[]>(`rplist_${albumId}`) || [];
    for (let cid of chapters) {
      this.prefs?.deleteSync(`rpos_${albumId}_${cid}`);
    }
    this.prefs?.deleteSync(`rplist_${albumId}`);
    this.prefs?.flushSync();
  }

  /** 把漫画 ID 记入索引，供「清除全部阅读位置」遍历（写多一次 preferences，量极小） */
  private trackPosAlbum(albumId: number): void {
    let albums = this.getObject<number[]>(CacheManager.KEY_POS_ALBUMS) || [];
    if (!albums.includes(albumId)) {
      albums.push(albumId);
      this.putObject(CacheManager.KEY_POS_ALBUMS, albums);
    }
  }

  /**
   * 清空全部漫画的阅读位置（rpos_* / rplist_* / rlast_*）
   * 已读章节标记 read_* 保留：章节仍显示"已读"，但不再自动跳到上次位置/章节。
   * @returns 清除的漫画数量
   */
  clearAllReadPositions(): number {
    let albums = this.getObject<number[]>(CacheManager.KEY_POS_ALBUMS) || [];
    for (let albumId of albums) {
      this.clearReadPositions(albumId);
      this.prefs?.deleteSync(`rlast_${albumId}`);
    }
    this.prefs?.deleteSync(CacheManager.KEY_POS_ALBUMS);
    this.prefs?.flushSync();
    return albums.length;
  }
}

/** 缓存分页条目 */
export interface CachePageEntry {
  data: string;
  total: number;
  timestamp: number;
  extra?: string;
}

/** 阅读位置（章节内图片索引） */
export interface ReadPosition {
  index: number;   // 章节内图片索引
  total: number;   // 总页数（用于校验）
  tick: number;    // 记录时间戳
}
