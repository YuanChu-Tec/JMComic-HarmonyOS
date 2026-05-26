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
  private static MAX_SEARCH_HISTORY = 20;

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

  /**
   * 保存首页列表数据
   * @param category 分类
   * @param order 排序
   * @param page 页码
   * @param albums 列表数据 JSON 字符串
   * @param total 总数
   */
  saveCategoryList(category: string, order: string, page: number, albums: string, total: number): void {
    let key = `cat_${category}_${order}`;
    let pageKey = `${key}_p${page}`;
    let entry: CachePageEntry = {
      data: albums,
      total: total,
      timestamp: Date.now()
    };
    this.putObject(pageKey, entry);
    // 更新页码索引
    let index = this.getObject<number[]>(`${key}_pages`) || [];
    if (!index.includes(page)) {
      index.push(page);
      this.putObject(`${key}_pages`, index);
    }
  }

  /**
   * 加载首页列表数据
   * @param category 分类
   * @param order 排序
   * @param page 页码
   * @returns 缓存的数据或 null（过期/不存在）
   */
  loadCategoryList(category: string, order: string, page: number): CachePageEntry | null {
    let key = `cat_${category}_${order}`;
    let pageKey = `${key}_p${page}`;
    let entry = this.getObject<CachePageEntry>(pageKey);
    if (!entry) return null;
    if (Date.now() - entry.timestamp > CacheManager.TTL_CATEGORY) {
      return null; // 过期
    }
    return entry;
  }

  /**
   * 获取某分类+排序下的所有已缓存页码（用于初始化列表）
   */
  getCategoryPages(category: string, order: string): number[] {
    let key = `cat_${category}_${order}`;
    return this.getObject<number[]>(`${key}_pages`) || [];
  }

  /**
   * 清除某分类缓存
   */
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
    // 去重并移到最前
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
    // 页码索引
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

  /**
   * 缓存章节图片元数据（PictureData 的 JSON）
   * key 格式: chapter_{photoId}
   * 永不过期，只在用户手动清除或覆盖时更新
   */
  saveChapterData(photoId: string, dataJson: string): void {
    this.put(`chapter_${photoId}`, dataJson);
  }

  /**
   * 加载缓存的章节图片元数据
   * @returns JSON 字符串或 null
   */
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
}

/** 缓存分页条目 */
export interface CachePageEntry {
  data: string;
  total: number;
  timestamp: number;
  extra?: string; // 额外数据（如 folders JSON）
}
