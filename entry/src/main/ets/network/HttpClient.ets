import { http } from '@kit.NetworkKit';
import { APP_HEADERS_TEMPLATE, DEFAULT_RETRY_TIMES } from '../common/Constants';

/**
 * HTTP 网络请求客户端
 * 封装 @ohos.net.http，提供重试机制
 */
export class HttpClient {
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

      if (response.responseCode === 200) {
        return response.result as string;
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
