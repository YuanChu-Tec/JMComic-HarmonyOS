import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { SCRAMBLE_268850, SCRAMBLE_421926 } from './Constants';

/**
 * 图片解密工具类
 * 实现 JMComic 图片的 scramble 解码算法
 * 对应 Python 项目中的 JmImageTool
 */
export class ImageDecodeUtils {
  /**
   * 计算图片分割数
   * 对应 Python: JmImageTool.get_num(scramble_id, aid, filename)
   *
   * @param scrambleId scramble_id
   * @param aid album/photo id
   * @param filename 图片文件名（不含后缀，如 "00001"）
   * @returns 分割数，0 表示不需要解密
   */
  static async getSegmentationNum(
    scrambleId: number,
    photoId: number,
    filename: string
  ): Promise<number> {
    if (photoId < scrambleId) {
      return 0;
    }
    if (photoId < SCRAMBLE_268850) {
      return 10;
    }

    let x: number = photoId < SCRAMBLE_421926 ? 10 : 8;
    let s: string = `${photoId}${filename}`;
    let md5Hex: string = await ImageDecodeUtils.md5HexString(s);
    let lastChar: string = md5Hex[md5Hex.length - 1];
    let num: number = lastChar.charCodeAt(0);
    num = num % x;
    num = num * 2 + 2;
    return num;
  }

  /**
   * 解密图片
   * 通过重新排列水平条带还原原始图片
   * 对应 QT: ToolUtil.SegmentationPicture() — tool.py:903-943
   *
   * 使用 readPixelsToBuffer + writeBufferToPixels 在同格式 PixelMap 之间操作，
   * 字节顺序由框架自动保持一致，无需手动处理通道转换。
   *
   * @param pixelMap 原始加密图片的 PixelMap
   * @param num 分割数
   * @returns 解密后的 PixelMap
   */
  static async decodeImage(pixelMap: image.PixelMap, num: number): Promise<image.PixelMap> {
    if (num === 0 || num === 1) {
      return pixelMap;
    }

    let imageInfo: image.ImageInfo = await pixelMap.getImageInfo();
    let w: number = imageInfo.size.width;
    let h: number = imageInfo.size.height;

    console.info(`[ImageDecode] format=${imageInfo.pixelFormat}, alphaType=${imageInfo.alphaType}, size=${w}x${h}, num=${num}`);

    let rem: number = h % num;
    let copyHeight: number = Math.floor(h / num);
    let rowBytes: number = w * 4;

    // 1. 读取全部像素（字节顺序由 PixelMap 内部格式决定）
    let srcBuffer: ArrayBuffer = new ArrayBuffer(w * h * 4);
    await pixelMap.readPixelsToBuffer(srcBuffer);
    let srcArr: Uint8Array = new Uint8Array(srcBuffer);

    // 2. 创建重排后的像素缓冲区
    let dstArr: Uint8Array = new Uint8Array(w * h * 4);

    // 3. 计算 block 列表: [(startRow, endRow), ...]
    let blockStart: number[] = [];
    let blockEnd: number[] = [];
    let totalH: number = 0;
    for (let i = 0; i < num; i++) {
      let bh: number = copyHeight * (i + 1);
      if (i === num - 1) {
        bh += rem;
      }
      blockStart.push(totalH);
      blockEnd.push(bh);
      totalH = bh;
    }

    // 4. 倒序遍历 block，按条带拷贝到目标
    let dstY: number = 0;
    for (let i = num - 1; i >= 0; i--) {
      let start: number = blockStart[i];
      let end: number = blockEnd[i];
      let coH: number = end - start;
      let srcOff: number = start * rowBytes;
      let dstOff: number = dstY * rowBytes;
      let stripSize: number = coH * rowBytes;

      dstArr.set(srcArr.slice(srcOff, srcOff + stripSize), dstOff);
      dstY += coH;
    }

    // 5. 创建同格式目标 PixelMap 并写入重排后的像素
    //    readPixelsToBuffer 与 writeBufferToPixels 在相同格式的 PixelMap 上
    //    使用一致的字节顺序，无需手动处理 BGRA/RGBA 通道
    let blankBuffer: ArrayBuffer = new ArrayBuffer(w * h * 4);
    let initOpts: image.InitializationOptions = {
      editable: true,
      pixelFormat: imageInfo.pixelFormat,
      size: { width: w, height: h },
      alphaType: imageInfo.alphaType
    };
    let target: image.PixelMap = image.createPixelMapSync(blankBuffer, initOpts);
    await target.writeBufferToPixels(dstArr.buffer.slice(dstArr.byteOffset, dstArr.byteOffset + dstArr.byteLength));

    return target;
  }

  /**
   * MD5 辅助函数，返回 hex 字符串
   */
  private static async md5HexString(input: string): Promise<string> {
    let md = cryptoFramework.createMd('MD5');
    let encoder = new util.TextEncoder();
    await md.update({ data: encoder.encodeInto(input) });
    let result = await md.digest();
    let hexChars: string[] = [];
    for (let i = 0; i < result.data.length; i++) {
      let hex: string = result.data[i].toString(16);
      hexChars.push(hex.length === 1 ? '0' + hex : hex);
    }
    return hexChars.join('');
  }
}


