import { HttpClient } from './HttpClient';
import { DomainManager } from './DomainManager';
import { CryptoUtils } from '../common/CryptoUtils';
import {
  DOMAIN_API_LIST,
  DOMAIN_IMAGE_LIST,
  PROT,
  API_SEARCH,
  API_ALBUM,
  API_CHAPTER,
  API_SCRAMBLE,
  API_CATEGORIES_FILTER,
  API_FAVORITE,
  API_FAVORITE_FOLDER,
  API_LOGIN,
  PAGE_SIZE_SEARCH,
  PAGE_SIZE_FAVORITE,
  IMAGE_SUFFIX_LIST,
  APP_HEADERS_IMAGE,
  APP_TOKEN_SECRET,
  APP_TOKEN_SECRET_2,
  DEFAULT_RETRY_TIMES,
} from '../common/Constants';
import {
  JmApiResponse,
  JmAlbumDetail,
  JmPromoteSection,
  SearchResultData,
  AlbumDetailData,
  PictureData,
  JmImageInfo,
  FavoritePageData,
  FavoriteActionResult,
  FavoriteFolderType,
  JmUserData,
  UserSession,
} from '../models/Album';

/**
 * API 服务层
 * 封装所有 JMComic API 调用
 * 对应 Python 项目中的 JmApiClient
 *
 * 域名管理增强：
 * - 集成 DomainManager 实现域名故障转移
 * - 请求失败时自动切换域名重试
 * - 后台定期探活恢复不可达域名
 */
export class ApiService {
  private domainManager: DomainManager;
  private userSession: UserSession = new UserSession();

  constructor() {
    this.domainManager = new DomainManager(DOMAIN_API_LIST, DOMAIN_IMAGE_LIST);
    // 启动后台定期复探
    this.domainManager.startPeriodicProbe();
  }

  // ─── 域名管理 ───

  /** 获取域名管理器（供外部调试） */
  getDomainManager(): DomainManager {
    return this.domainManager;
  }

  /** 执行域名探活，通常在应用启动时调用 */
  async probeDomains(): Promise<void> {
    await this.domainManager.probeAllDomains();
  }

  /** 手动切换域名（获取下一个最佳域名） */
  refreshDomains(): void {
    // DomainManager 内部已自动管理最佳域名选择
    // 此方法保留供外部手动触发探活
    console.info('[ApiService] refreshDomains: 当前最佳 API=' +
      this.domainManager.getBestApiDomain() +
      ' 图片=' + this.domainManager.getBestImageDomain());
  }

  getImageDomain(): string {
    return this.domainManager.getBestImageDomain();
  }

  /** 获取当前最佳图片 CDN 基础 URL (域名已含 cdn-msp. 前缀) */
  private getImageBaseUrl(): string {
    return PROT + this.domainManager.getBestImageDomain();
  }

  /**
   * 构建封面图 URL
   * @param albumId  album id
   * @param size     尺寸后缀: 列表页 "_3x4", 详情页 ""
   */
  buildCoverUrl(albumId: string | number, size: string = '_3x4'): string {
    return `${this.getImageBaseUrl()}/media/albums/${albumId}${size}.jpg`;
  }

  // ─── 核心请求方法（带域名故障转移） ───

  /**
   * 带域名故障转移的 API 请求
   *
   * 核心逻辑：
   * 1. 从 DomainManager 获取最佳域名
   * 2. 构建完整 URL 并发起请求
   * 3. 成功 → 报告成功、返回结果
   * 4. 失败 → 报告失败、获取下一个最佳域名、重试
   *
   * 这个方法是所有 API 调用的统一入口，对应 Java RetryAndDomainRedirectInterceptor
   *
   * @param path      API 路径 (如 '/search')
   * @param method    GET 或 POST
   * @param body      请求体 (POST 时使用，form-urlencoded 字符串)
   * @param headers   请求头
   * @param maxDomainSwitches 最大域名切换次数（默认尝试所有域名）
   * @returns 响应 body 字符串
   */
  private async requestApi(
    path: string,
    method: 'GET' | 'POST',
    body: string | null,
    headers: Record<string, string>,
    maxDomainSwitches: number = DOMAIN_API_LIST.length
  ): Promise<string> {
    let lastErr: Error | null = null;
    let triedDomains: Set<string> = new Set();

    for (let attempt = 0; attempt < maxDomainSwitches; attempt++) {
      let domain = this.domainManager.getBestApiDomain();

      // 跳过已尝试过的域名（避免循环使用同一域名）
      if (triedDomains.has(domain)) {
        continue;
      }
      triedDomains.add(domain);

      let url = `${PROT}${domain}${path}`;

      try {
        let result: string;
        if (method === 'GET') {
          // GET 请求使用单次尝试（域名切换在外层处理）
          result = await HttpClient.get(url, headers, 1);
        } else {
          // POST 请求使用单次尝试
          result = await HttpClient.post(url, body || '', headers, 1);
        }
        // 请求成功，报告域名成功
        this.domainManager.reportApiSuccess(domain);
        console.info(`[ApiService] ✓ ${domain}${path}`);
        return result;
      } catch (err) {
        lastErr = err as Error;
        // 请求失败，报告域名失败
        this.domainManager.reportApiFailure(domain);
        console.warn(`[ApiService] ✗ ${domain}${path} (attempt ${attempt + 1}/${maxDomainSwitches}): ${lastErr.message}`);

        if (attempt < maxDomainSwitches - 1) {
          await HttpClient.sleep(500);
        }
      }
    }

    throw lastErr || new Error(`所有 API 域名请求均失败: ${path}`);
  }

  // ─── 搜索 ───

  /**
   * 搜索漫画
   * 对应 QT: GetSearchReq2 — GET /search?search_query=xxx&page=N&o=mr
   *
   * @param keyword 搜索关键词
   * @param page 页码 (从 1 开始)
   * @returns 搜索结果
   */
  async search(keyword: string, page: number = 1): Promise<JmApiResponse<SearchResultData>> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let queryParams: Record<string, string> = {};
    queryParams['main_tag'] = '0';
    queryParams['search_query'] = keyword;
    queryParams['page'] = page.toString();
    queryParams['o'] = 'mr';
    queryParams['t'] = 'a';
    let queryString = ApiService.buildFormBody(queryParams);

    let path = `${API_SEARCH}?${queryString}`;

    let respStr = await this.requestApi(path, 'GET', null, headers);
    return await this.decryptResponse<SearchResultData>(respStr, ts);
  }

  /**
   * 获取首页推荐分类列表
   * 对应 QT: GetIndexInfoReq2 — GET /promote?page=0
   *
   * 返回数据结构: [{title: "最新上传", content: [JmAlbumInfo, ...]}, ...]
   */
  async getPromote(page: number = 0): Promise<JmApiResponse<JmPromoteSection[]>> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let path = `/promote?page=${page}`;

    let respStr = await this.requestApi(path, 'GET', null, headers);
    return await this.decryptResponse<JmPromoteSection[]>(respStr, ts);
  }

  /**
   * 获取分类列表 (首页推荐)
   * 对应 QT: GetSearchCategoryReq2 — GET /categories/filter/?c=0&page=N&o=mr
   *
   * @param category 分类标识
   * @param order 排序方式
   * @param page 页码
   */
  async getCategoryList(
    category: string = '0',
    order: string = 'mr',
    page: number = 1
  ): Promise<JmApiResponse<SearchResultData>> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let queryParams: Record<string, string> = {};
    queryParams['page'] = page.toString();
    queryParams['order'] = '';
    queryParams['o'] = order;
    if (category && category !== '0') {
      queryParams['c'] = category;
    }
    let queryString = ApiService.buildFormBody(queryParams);

    let path = `${API_CATEGORIES_FILTER}?${queryString}`;

    let respStr = await this.requestApi(path, 'GET', null, headers);
    return await this.decryptResponse<SearchResultData>(respStr, ts);
  }

  // ─── Album 详情 ───

  /**
   * 获取 Album 详情
   * 对应 QT: GetBookInfoReq2 — GET /album/?comicName=&id=xxx
   *
   * @param albumId Album ID
   */
  async getAlbumDetail(albumId: number): Promise<JmApiResponse<JmAlbumDetail>> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let queryParams: Record<string, string> = {};
    queryParams['id'] = albumId.toString();
    let queryString = ApiService.buildFormBody(queryParams);

    let path = `${API_ALBUM}?${queryString}`;

    let respStr = await this.requestApi(path, 'GET', null, headers);
    return await this.decryptResponse<JmAlbumDetail>(respStr, ts);
  }

  // ─── 图片/章节 ───

  /**
   * 获取章节的图片列表
   * 对应 QT: GetBookEpsInfoReq2 — GET /chapter/?comicName=&skip=&id=xxx
   * 对应 QT: GetBookEpsScrambleReq2 — GET /chapter_view_template/?id=xxx&mode=vertical&page=0&app_img_shunt=NaN
   *
   * 正确流程：
   * 1. GET /chapter?id=xxx → 获取图片文件名等元数据
   * 2. GET /chapter_view_template?id=xxx&mode=vertical&page=0&app_img_shunt=NaN → 从 HTML 提取 scramble_id
   * 3. 用 scramble_id + imageDomain 构建正确的图片 URL
   *
   * @param photoId photo_id
   * @param scrambleId scramble_id（从 album detail 预取，作为 fallback）
   */
  async getChapterPictures(photoId: string, scrambleId: number): Promise<PictureData> {
    // ── 步骤 1: GET /chapter 获取图片元数据 ──
    // 对应 QT: GetBookEpsInfoReq2 — GET /chapter/?comicName=&skip=&id={epsId}
    let ts1 = CryptoUtils.timestamp();
    let headers1 = await this.buildTokenHeaders(ts1);

    let chapterParams: Record<string, string> = {};
    chapterParams['comicName'] = '';
    chapterParams['skip'] = '';
    chapterParams['id'] = photoId;
    let chapterQuery = ApiService.buildFormBody(chapterParams);
    let chapterPath = `${API_CHAPTER}/?${chapterQuery}`;

    let chapterResp = await this.requestApi(chapterPath, 'GET', null, headers1);
    // /chapter 解密后是扁平结构: {id, name, series_id, series, tags, images: ["f1.webp", ...]}
    // 不能用 PictureData 泛型，直接按 Record 解析
    let apiResp = await this.decryptResponse<Record<string, Object>>(chapterResp, ts1);

    if (apiResp.code !== 200) {
      throw new Error(`获取章节失败: code=${apiResp.code}, msg=${apiResp.message}`);
    }
    let raw = apiResp.data;
    if (!raw) {
      throw new Error('章节数据为空，photoId=' + photoId);
    }

    // ── 步骤 2: GET /chapter_view_template 获取 scramble_id ──
    // 该接口使用 APP_TOKEN_SECRET_2 密钥
    let ts2 = CryptoUtils.timestamp();
    let headers2 = await this.buildTokenHeaders(ts2, APP_TOKEN_SECRET_2);

    let fetchedScrambleId: number = scrambleId;
    try {
      let scrambleParams: Record<string, string> = {};
      scrambleParams['id'] = photoId;
      scrambleParams['mode'] = 'vertical';
      scrambleParams['page'] = '0';
      scrambleParams['app_img_shunt'] = 'NaN';
      let scrambleQuery = ApiService.buildFormBody(scrambleParams);
      let scramblePath = `${API_SCRAMBLE}?${scrambleQuery}`;

      let scrambleHtml = await this.requestApi(scramblePath, 'GET', null, headers2);
      // 从 HTML 中提取 var scramble_id = 220980;
      let regex = /var scramble_id = (\d+);/;
      let match = scrambleHtml.match(regex);
      if (match && match[1]) {
        fetchedScrambleId = parseInt(match[1]);
        console.info(`[ApiService] fetched scramble_id=${fetchedScrambleId} for photo=${photoId}`);
      } else {
        console.warn(`[ApiService] scramble_id not found in HTML, using fallback=${scrambleId}`);
      }
    } catch (err) {
      console.error(`[ApiService] fetch scramble_id failed: ${JSON.stringify(err)}, using fallback=${scrambleId}`);
    }

    // ── 步骤 3: 构建正确的图片 URL ──
    // images 是文件名字符串数组: ["00001.webp", "00002.webp", ...]
    let imageBaseUrl = this.getImageBaseUrl();
    let rawImages: string[] = raw['images'] as string[] || [];
    let photoName: string = (raw['name'] as string) || '';

    let jmImages: JmImageInfo[] = [];
    for (let filename of rawImages) {
      let imgUrl = `${imageBaseUrl}/media/photos/${photoId}/${filename}`;
      jmImages.push({
        img_name: filename,
        img_url: imgUrl,
        download_url: imgUrl,
      });
    }

    // 封装为 PictureData 返回
    return {
      pictures: {
        id: parseInt(photoId) || 0,
        photo_id: photoId,
        name: photoName,
        images: jmImages,
        scramble_id: fetchedScrambleId,
      }
    };
  }

  // ─── 收藏系统 ───

  /**
   * 获取收藏夹分页数据
   * 对应 Java: JmApiClient.getFavorites(FavoriteQuery)
   * 对应 Python: JmApiClient.favorite_folder()
   *
   * API: GET /favorite?page=N&folder_id=N (需要登录 cookies)
   *
   * @param page 页码（从1开始）
   * @param folderId 收藏夹ID，'0'表示全部
   * @returns 收藏夹一页数据
   */
  async getFavorites(page: number = 1, folderId: string = '0'): Promise<JmApiResponse<FavoritePageData>> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let path = `${API_FAVORITE}?page=${page}&folder_id=${folderId}`;
    let respStr = await this.requestApi(path, 'GET', null, headers);
    return await this.decryptResponse<FavoritePageData>(respStr, ts);
  }

  /**
   * 切换收藏状态（收藏/取消收藏）
   * 服务端自动判断：已收藏则取消，未收藏则添加
   *
   * API: POST /favorite  body: aid=albumId
   * 对应 Java: JmApiClient.toggleAlbumFavorite()
   * 对应 Python: JmApiClient.add_favorite_album()
   *
   * @param albumId 本子ID
   * @returns 操作结果 {status: "ok", msg: "..."}
   */
  async toggleFavorite(albumId: string): Promise<FavoriteActionResult> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let bodyParams: Record<string, string> = {};
    bodyParams['aid'] = albumId;
    let body = ApiService.buildFormBody(bodyParams);

    let respStr = await this.requestApi(API_FAVORITE, 'POST', body, headers);
    let resp = await this.decryptResponse<FavoriteActionResult>(respStr, ts);
    if (resp.code !== 200) {
      throw new Error(resp.message || '收藏操作失败');
    }
    return resp.data;
  }

  /**
   * 管理收藏夹（新建/重命名/移动/删除文件夹）
   *
   * API: POST /favorite_folder
   * 对应 Java: JmApiClient.manageFavoriteFolder()
   *
   * @param type       操作类型：add/edit/move/del
   * @param folderId   文件夹ID
   * @param folderName 文件夹名称（add/edit时需要）
   * @param albumId    本子ID（move时需要）
   * @returns 操作结果
   */
  async manageFavoriteFolder(
    type: FavoriteFolderType,
    folderId: string = '',
    folderName: string = '',
    albumId: string = ''
  ): Promise<FavoriteActionResult> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let params: Record<string, string> = {};
    params['type'] = type;
    if (folderId) {
      params['folder_id'] = folderId;
    }
    if (folderName) {
      params['folder_name'] = folderName;
    }
    if (albumId) {
      params['aid'] = albumId;
    }

    let body = ApiService.buildFormBody(params);
    let respStr = await this.requestApi(API_FAVORITE_FOLDER, 'POST', body, headers);
    let resp = await this.decryptResponse<FavoriteActionResult>(respStr, ts);
    if (resp.code !== 200) {
      throw new Error(resp.message || '收藏夹操作失败');
    }
    return resp.data;
  }

  // ─── 登录系统 ───

  /**
   * 用户登录
   * 对应 Python: JmApiClient.login() — App API 版本
   * 对应 QT: LoginReq2 — POST /login {username, password}
   *
   * API: POST /login
   * body: username=xxx&password=xxx
   *
   * 返回用户信息，同时将 session token 存入内部 session
   *
   * @param username 用户名
   * @param password 密码
   * @returns 用户信息
   */
  async login(username: string, password: string): Promise<UserSession> {
    let ts = CryptoUtils.timestamp();
    let headers = await this.buildTokenHeaders(ts);

    let bodyParams: Record<string, string> = {};
    bodyParams['username'] = username;
    bodyParams['password'] = password;
    let body = ApiService.buildFormBody(bodyParams);

    let respStr = await this.requestApi(API_LOGIN, 'POST', body, headers);

    // login 响应也是加密的（双层结构），需要解密
    let resp = await this.decryptResponse<JmUserData>(respStr, ts);
    if (resp.code !== 200) {
      throw new Error(resp.message || '登录失败');
    }

    this.userSession = UserSession.fromApiData(resp.data);
    console.info(`[ApiService] login success: uid=${this.userSession.uid}, username=${this.userSession.username}`);
    return this.userSession;
  }

  /**
   * 检查用户是否已登录
   */
  isLoggedIn(): boolean {
    return this.userSession.isLoggedIn;
  }

  /**
   * 获取当前用户会话
   */
  getUserSession(): UserSession {
    return this.userSession;
  }

  /**
   * 退出登录
   */
  logout(): void {
    this.userSession.logout();
    console.info('[ApiService] logout');
  }

  // ─── 辅助方法 ───

  /**
   * 构建带 token/tokenparam 的请求头
   * 对应 QT: ServerReq.GetHeader()
   *
   * token = MD5(timestamp + secret)
   * tokenparam = "timestamp,version"
   *
   * @param ts 时间戳字符串
   * @param secret 密钥，默认 APP_TOKEN_SECRET
   */
  private async buildTokenHeaders(
    ts: string,
    secret: string = APP_TOKEN_SECRET
  ): Promise<Record<string, string>> {
    let tokenResult = await CryptoUtils.tokenAndTokenparam(ts, secret);
    return {
      'token': tokenResult[0],
      'tokenparam': tokenResult[1],
    };
  }

  /**
   * 解密 API 响应
   *
   * 响应为双层结构：
   * 外层明文 JSON: {"code": 200, "data": "<base64加密字符串>", "message": "..."}
   * data 字段: base64 → AES-ECB 解密 → 明文 JSON: {"total": "...", "content": [...]}
   *
   * 对应 QT: v = json.loads(response); result = ParseData(v.get("data"))
   */
  private async decryptResponse<T>(respStr: string, ts: string): Promise<JmApiResponse<T>> {
    // 1. 解析外层 JSON
    let outer: JmApiResponse<T>;
    try {
      outer = JSON.parse(respStr) as JmApiResponse<T>;
    } catch (_) {
      // 整个响应不是 JSON，尝试整体解密
      let decrypted = await CryptoUtils.decodeRespData(respStr, ts);
      return JSON.parse(decrypted) as JmApiResponse<T>;
    }

    // 2. 检查 code，如果请求失败直接返回
    if (outer.code !== 200) {
      return outer;
    }

    // 3. data 字段是 base64 加密字符串，需要解密
    if (typeof outer.data === 'string' && (outer.data as string).length > 0) {
      try {
        let decrypted = await CryptoUtils.decodeRespData(outer.data as string, ts);
        let innerData = JSON.parse(decrypted) as T;
        outer.data = innerData;
      } catch (err) {
        console.error(`[ApiService] decryptResponse data field error: ${JSON.stringify(err)}`);
        console.error(`[ApiService] raw data field: ${(outer.data as string).substring(0, 100)}`);
        throw err as Error;
      }
    }

    return outer;
  }

  /**
   * 构建 form-urlencoded body
   */
  private static buildFormBody(params: Record<string, string>): string {
    let parts: string[] = [];
    let keys = Object.keys(params);
    for (let i = 0; i < keys.length; i++) {
      let k = keys[i];
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
    }
    return parts.join('&');
  }

  /**
   * 构建图片 URL
   * 使用 DomainManager 获取最佳图片域名
   */
  getImageUrl(imgName: string, photoId: string | number): string {
    let baseUrl = this.getImageBaseUrl();
    return `${baseUrl}/media/photos/${photoId}/${imgName}`;
  }

  /**
   * 获取图片 URL（带后缀探测）
   */
  getImageUrlWithSuffix(imgName: string, photoId: string | number, suffix: string = '.jpg'): string {
    let baseUrl = this.getImageBaseUrl();
    return `${baseUrl}/media/photos/${photoId}/${imgName}${suffix}`;
  }

  // ─── 清理 ───

  /** 释放资源（关闭后台探活定时器） */
  destroy(): void {
    this.domainManager.shutdown();
  }
}
