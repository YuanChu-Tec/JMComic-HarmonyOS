import { preferences } from '@kit.ArkData';

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
  private static TTL_CATEGORY = 30 * 60 * 1000; // 30 分钟
  private static TTL_FAVORITE = 10 * 60 * 1000; // 10 分钟
  private static TTL_SEARCH_RESULT = 30 * 60 * 1000; // 30 分钟
  private static MAX_SEARCH_HISTORY = 9999;

  private static instance: CacheManager | null = null;
  private prefs: preferences.Preferences | null = null;

  private constructor() {
  }

  static async getInstance(): Promise<CacheManager> {
    if (CacheManager.instance === null) {
      CacheManager.instance = new CacheManager();
    }
    if (CacheManager.instance.prefs === null) {
      CacheManager.instance.prefs = await preferences.getPreferences(getContext(), CacheManager.PREF_NAME);
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

  // ─── 章节图片数据缓存 ───

  saveChapterData(photoId: string, dataJson: string): void {
    this.put(`chapter_${photoId}`, dataJson);
  }

  loadChapterData(photoId: string): string | null {
    return this.getString(`chapter_${photoId}`) || null;
  }

  // ─── 下载任务 ───

  saveDownloadTasks(tasks: string): void {
    this.put('download_tasks', tasks);
  }

  loadDownloadTasks(): string {
    return this.getString('download_tasks', '[]');
  }

  // ─── 阅读历史（已读章节标记） ───

  markChapterRead(albumId: number, chapterId: string): void {
    this.put(`read_${albumId}_${chapterId}`, Date.now().toString());
    // 同时更新最后阅读章节
    this.put(`lastread_${albumId}`, chapterId);
  }

  isChapterRead(albumId: number, chapterId: string): boolean {
    let val = this.getString(`read_${albumId}_${chapterId}`);
    return val !== '';
  }

  getLastReadChapterId(albumId: number): string {
    return this.getString(`lastread_${albumId}`);
  }

  getChapterReadTime(albumId: number, chapterId: string): number {
    let val = this.getString(`read_${albumId}_${chapterId}`);
    return val ? parseInt(val) : 0;
  }
}

/** 缓存分页条目 */
export interface CachePageEntry {
  data: string;
  total: number;
  timestamp: number;
  extra?: string;
}
