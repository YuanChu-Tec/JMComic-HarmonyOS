import { http } from '@kit.NetworkKit';
import { APP_HEADERS_TEMPLATE, DEFAULT_RETRY_TIMES } from '../common/Constants';

/**
 * HTTP 网络请求客户端
 * 封装 @ohos.net.http，提供重试机制和 Cookie 管理
 */
export class HttpClient {
  // 全局 Cookie 存储（模拟 Session）
  private static globalCookies: Map<string, string> = new Map();

  /**
   * 设置全局 Cookie
   * @param name Cookie 名称
   * @param value Cookie 值
   */
  static setCookie(name: string, value: string): void {
    HttpClient.globalCookies.set(name, value);
    console.info(`[HttpClient] Set cookie: ${name}=${value.substring(0, 20)}...`);
  }

  /**
   * 强制更新 Cookie（用于需要主动更新的场景）
   * @param name Cookie 名称
   * @param value Cookie 值
   */
  static forceSetCookie(name: string, value: string): void {
    HttpClient.globalCookies.set(name, value);
    console.info(`[HttpClient] Force update cookie: ${name}=${value.substring(0, 20)}...`);
  }

  /**
   * 清除所有 Cookies（用于登出或重新初始化）
   */
  static clearAllCookies(): void {
    HttpClient.globalCookies.clear();
    console.info('[HttpClient] All cookies cleared');
  }

  /**
   * 获取所有 Cookies 字符串（用于 Cookie header）
   * @returns Cookie 字符串，格式: "name1=value1; name2=value2"
   */
  static getCookiesString(): string {
    let cookies: string[] = [];
    // 确保重要cookie优先添加
    let importantCookies = ['AVS', 'ipcountry', 'ipm5', '__cflb'];
    
    // 先添加重要的cookies（按固定顺序）
    for (let key of importantCookies) {
      if (HttpClient.globalCookies.has(key)) {
        cookies.push(`${key}=${HttpClient.globalCookies.get(key)}`);
      }
    }
    
    // 再添加其他cookies
    HttpClient.globalCookies.forEach((value, key) => {
      if (!importantCookies.includes(key)) {
        cookies.push(`${key}=${value}`);
      }
    });
    
    let result = cookies.join('; ');
    console.info(`[HttpClient] getCookiesString: ${result.length > 0 ? result.substring(0, 100) + '...' : '(empty)'}, count=${HttpClient.globalCookies.size}`);
    return result;
  }

  /**
   * 从响应头中解析并保存 Cookies（合并模式，不会覆盖已有的重要 cookies）
   * @param headers 响应头
   */
  static parseAndSaveCookies(headers: Record<string, string | string[]>): void {
    let setCookieHeaders = headers['set-cookie'];
    if (!setCookieHeaders) {
      return;
    }

    // set-cookie 可能是数组或字符串
    let cookieStrings: string[] = [];
    if (Array.isArray(setCookieHeaders)) {
      cookieStrings = setCookieHeaders as string[];
    } else {
      cookieStrings = [setCookieHeaders as string];
    }

    for (let cookieStr of cookieStrings) {
      // 解析 "name=value; Path=/; ..." 格式
      let firstSemicolon = cookieStr.indexOf(';');
      let cookiePart = firstSemicolon > 0 ? cookieStr.substring(0, firstSemicolon) : cookieStr;
      let equalIndex = cookiePart.indexOf('=');
      if (equalIndex > 0) {
        let name = cookiePart.substring(0, equalIndex).trim();
        let value = cookiePart.substring(equalIndex + 1).trim();
        if (name && value) {
          // 关键修复：只有当该 cookie 不存在时才设置，或者允许更新某些特定的 cookie
          // 对于重要的认证 cookies（如 AVS），保留已有的值
          if (!HttpClient.globalCookies.has(name)) {
            HttpClient.setCookie(name, value);
          } else {
            // 如果已存在，记录日志但不覆盖（避免错误的 cookies 覆盖正确的）
            console.info(`[HttpClient] Cookie ${name} already exists, keeping existing value`);
          }
        }
      }
    }
  }
  /**
   * 发起 GET 请求
   * @param url 完整 URL
   * @param headers 额外的请求头
   * @param retries 重试次数
   * @returns 响应 body 字符串
   */
  static async get(
    url: string,
    headers: Record<string, string> = {},
    retries: number = DEFAULT_RETRY_TIMES
  ): Promise<string> {
    return HttpClient.requestWithRetry(url, http.RequestMethod.GET, null, headers, retries);
  }

  /**
   * 发起 POST 请求
   * @param url 完整 URL
   * @param body 请求体 (form-urlencoded 字符串)
   * @param headers 额外的请求头
   * @param retries 重试次数
   * @returns 响应 body 字符串
   */
  static async post(
    url: string,
    body: string = '',
    headers: Record<string, string> = {},
    retries: number = DEFAULT_RETRY_TIMES
  ): Promise<string> {
    return HttpClient.requestWithRetry(url, http.RequestMethod.POST, body, headers, retries);
  }

  /**
   * 带重试的请求
   */
  private static async requestWithRetry(
    url: string,
    method: http.RequestMethod,
    body: string | null,
    headers: Record<string, string>,
    retries: number
  ): Promise<string> {
    let lastErr: Error | null = null;

    for (let i = 0; i < retries; i++) {
      try {
        return await HttpClient.doRequest(url, method, body, headers);
      } catch (err) {
        lastErr = err as Error;
        console.warn(`HttpClient request failed (attempt ${i + 1}/${retries}): ${url}`);
        // 最后一次重试前等待
        if (i < retries - 1) {
          await HttpClient.sleep(1000 * (i + 1));
        }
      }
    }

    throw lastErr || new Error('Request failed after retries');
  }

  /**
   * 实际执行 HTTP 请求
   */
  private static async doRequest(
    url: string,
    method: http.RequestMethod,
    body: string | null,
    extraHeaders: Record<string, string>
  ): Promise<string> {
    let request = http.createHttp();

    // 合并请求头
    let allHeaders: Record<string, string> = HttpClient.mergeHeaders(APP_HEADERS_TEMPLATE, extraHeaders);

    // 添加 Cookie header（如果有 cookies）
    let cookiesStr = HttpClient.getCookiesString();
    if (cookiesStr.length > 0) {
      allHeaders['Cookie'] = cookiesStr;
      console.info(`[HttpClient] Sending cookies: ${cookiesStr.substring(0, 50)}...`);
    }

    if (method === http.RequestMethod.POST && body) {
      allHeaders['Content-Type'] = allHeaders['Content-Type'] || 'application/x-www-form-urlencoded';
    }

    try {
      let response = await request.request(url, {
        method: method,
        header: allHeaders,
        extraData: body || undefined,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000,
      });

      // 只在成功响应时保存 Cookies，避免错误响应覆盖正确的 cookies
      if (response.responseCode === 200) {
        HttpClient.parseAndSaveCookies(response.header as Record<string, string | string[]>);
        return HttpClient.sanitizeResponseText(response.result as string);
      }

      throw new Error(`HTTP ${response.responseCode}: ${url}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * 下载二进制数据（图片等）
   * @param url 完整 URL
   * @param headers 额外的请求头
   * @returns ArrayBuffer
   */
  static async downloadBinary(
    url: string,
    headers: Record<string, string> = {}
  ): Promise<ArrayBuffer> {
    let request = http.createHttp();

    let allHeaders: Record<string, string> = HttpClient.mergeHeaders(APP_HEADERS_TEMPLATE, headers);

    try {
      let response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: allHeaders,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000,
        readTimeout: 60000,
      });

      if (response.responseCode === 200) {
        return response.result as ArrayBuffer;
      }

      throw new Error(`HTTP ${response.responseCode}: ${url}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * 清洗响应文本
   *
   * 部分服务器（JMComic CDN）返回的 JSON 会在开头带一个 UTF-8 BOM（U+FEFF，对应字节 EF BB BF），
   * 而 ArkTS 的 JSON.parse 不接受前置 BOM，会直接抛 SyntaxError。
   * 这里统一剥掉 BOM 及首尾空白，避免上层解析失败。
   *
   * @param text 原始响应文本
   * @returns 去除 BOM 与首尾空白后的文本
   */
  static sanitizeResponseText(text: string): string {
    let result = text;
    // BOM 可能出现多次（多层代理拼接），循环剥离
    while (result.length > 0 && result.charCodeAt(0) === 0xFEFF) {
      result = result.substring(1);
    }
    return result.trim();
  }

  /**
   * 合并两个 headers 对象（ArkTS 不允许对象展开，用此方法替代）
   */
  static mergeHeaders(
    base: Record<string, string>,
    extra: Record<string, string>
  ): Record<string, string> {
    let result: Record<string, string> = {};
    let baseKeys = Object.keys(base);
    for (let i = 0; i < baseKeys.length; i++) {
      result[baseKeys[i]] = base[baseKeys[i]];
    }
    let extraKeys = Object.keys(extra);
    for (let i = 0; i < extraKeys.length; i++) {
      result[extraKeys[i]] = extra[extraKeys[i]];
    }
    return result;
  }

  /**
   * 延迟 Promise
   */
  static sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
