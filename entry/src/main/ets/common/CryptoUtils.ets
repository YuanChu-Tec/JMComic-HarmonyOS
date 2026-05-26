import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { APP_TOKEN_SECRET, APP_TOKEN_SECRET_2, APP_DATA_SECRET, APP_VERSION } from './Constants';

/**
 * 加密工具类
 * 实现 JMComic APP 接口的 Token 计算和响应数据解密
 * 对应 Python 项目中的 JmCryptoTool
 */
export class CryptoUtils {
  /**
   * 计算 MD5 哈希，返回 hex 字符串
   * @param input 输入字符串
   * @returns MD5 hex 字符串 (32位小写)
   */
  static async md5Hex(input: string): Promise<string> {
    let md = cryptoFramework.createMd('MD5');
    await md.update({ data: CryptoUtils.stringToUint8Array(input) });
    let result = await md.digest();
    return CryptoUtils.uint8ArrayToHex(result.data);
  }

  /**
   * 计算 Token 和 Tokenparam
   * 对应 Python: token_and_tokenparam(ts, ver, secret)
   *
   * token = MD5(ts + secret)
   * tokenparam = "ts,ver"
   *
   * @param ts 时间戳字符串
   * @param secret 密钥，默认使用 APP_TOKEN_SECRET
   * @param ver APP版本，默认使用 APP_VERSION
   * @returns [token, tokenparam]
   */
  static async tokenAndTokenparam(
    ts: string,
    secret: string = APP_TOKEN_SECRET,
    ver: string = APP_VERSION
  ): Promise<[string, string]> {
    let tokenparam: string = `${ts},${ver}`;
    let token: string = await CryptoUtils.md5Hex(ts + secret);
    return [token, tokenparam];
  }

  /**
   * 使用特定密钥计算 Token（用于 /chapter_view_template 接口）
   * 该接口使用 APP_TOKEN_SECRET_2 而非 APP_TOKEN_SECRET
   */
  static async tokenForScramble(ts: string): Promise<[string, string]> {
    return CryptoUtils.tokenAndTokenparam(ts, APP_TOKEN_SECRET_2);
  }

  /**
   * 解密 API 响应数据
   * 对应 Python: decode_resp_data(data, ts, secret)
   *
   * 步骤：
   * 1. Base64 解码 data
   * 2. AES-256-ECB 解密 (key = md5(ts + secret), 32字节 key)
   * 3. 移除 PKCS7 padding
   * 4. UTF-8 解码为 JSON 字符串
   *
   * @param data base64 编码的加密数据
   * @param ts 请求时使用的时间戳
   * @param secret 数据密钥，默认使用 APP_DATA_SECRET
   * @returns 解密后的 JSON 字符串
   */
  static async decodeRespData(
    data: string,
    ts: string,
    secret: string = APP_DATA_SECRET
  ): Promise<string> {
    try {
      // 1. Base64 解码
      let base64Helper = new util.Base64Helper();
      let decodedBlob: Uint8Array = base64Helper.decodeSync(data);

      // 2. 生成 AES 密钥: md5(ts + secret) → hex string (32 bytes)
      let keyHex: string = await CryptoUtils.md5Hex(ts + secret);
      let keyBytes: Uint8Array = CryptoUtils.stringToUint8Array(keyHex);

      // 3. AES-256-ECB 解密
      let symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256');
      let symKey = await symKeyGenerator.convertKey({ data: keyBytes });
      let cipher = cryptoFramework.createCipher('AES256|ECB|PKCS7');
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
      let output: cryptoFramework.DataBlob = await cipher.doFinal({ data: decodedBlob });

      // 4. UTF-8 解码
      let textDecoder = util.TextDecoder.create('utf-8', { fatal: false });
      let result: string = textDecoder.decodeWithStream(output.data);

      return result;
    } catch (err) {
      console.error('CryptoUtils.decodeRespData error:', JSON.stringify(err));
      throw err as Error;
    }
  }

  /**
   * 将字符串转换为 Uint8Array (UTF-8 编码)
   */
  static stringToUint8Array(str: string): Uint8Array {
    let textEncoder = new util.TextEncoder();
    return textEncoder.encodeInto(str);
  }

  /**
   * 将 Uint8Array 转换为 hex 字符串
   */
  static uint8ArrayToHex(bytes: Uint8Array): string {
    let hexChars: string[] = [];
    for (let i = 0; i < bytes.length; i++) {
      let hex: string = bytes[i].toString(16);
      hexChars.push(hex.length === 1 ? '0' + hex : hex);
    }
    return hexChars.join('');
  }

  /**
   * 获取当前时间戳（秒级）
   */
  static timestamp(): string {
    return Math.floor(Date.now() / 1000).toString();
  }
}
