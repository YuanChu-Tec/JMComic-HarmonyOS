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
   * 算法：
   * 1. 将图片从上到下分成 num 个 block，每个高 copyHeight，最后一个额外加 remainder
   * 2. 倒序遍历 block，依次粘贴到目标图片从 y=0 开始
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
    let srcAlphaType: image.AlphaType = imageInfo.alphaType;

    // 读取原始像素数据（字节顺序与 pixelFormat 一致）
    let readBuffer: ArrayBuffer = new ArrayBuffer(w * h * 4);
    await pixelMap.readPixelsToBuffer(readBuffer);
    let srcPixels: Uint8ClampedArray = new Uint8ClampedArray(readBuffer);

    console.info(`[ImageDecode] format=${imageInfo.pixelFormat}, alphaType=${imageInfo.alphaType}, size=${w}x${h}, num=${num}`);

    // 如果源格式是 BGRA_8888，交换 R/B 通道转为 RGBA
    // readPixelsToBuffer 输出 BGRA 字节 [B,G,R,A]，
    // 但 createPixelMapSync 按 RGBA 解释，导致颜色偏蓝
    let isBGRA = (imageInfo.pixelFormat as number) === 4; // BGRA_8888 = 4
    if (isBGRA) {
      for (let p = 0; p < srcPixels.length; p += 4) {
        let bVal = srcPixels[p];
        srcPixels[p] = srcPixels[p + 2]; // R -> pos 0
        srcPixels[p + 2] = bVal;          // B -> pos 2
      }
      console.info('[ImageDecode] converted BGRA -> RGBA');
    }

    // 创建目标像素数组
    let dstPixels: Uint8ClampedArray = new Uint8ClampedArray(w * h * 4);

    let rem: number = h % num;
    let copyHeight: number = Math.floor(h / num);
    let rowBytes: number = w * 4;

    // 1. 计算 block 列表: [(start, end), ...]
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

    // 2. 倒序遍历 block，依次粘贴到目标
    let dstY: number = 0;
    for (let i = num - 1; i >= 0; i--) {
      let start: number = blockStart[i];
      let end: number = blockEnd[i];
      let coH: number = end - start;
      let srcOffset: number = start * rowBytes;
      let dstOffset: number = dstY * rowBytes;
      let stripSize: number = coH * rowBytes;

      dstPixels.set(
        srcPixels.slice(srcOffset, srcOffset + stripSize),
        dstOffset
      );
      dstY += coH;
    }

    // 输出始终为 RGBA_8888
    let arrayBuffer: ArrayBuffer = dstPixels.buffer.slice(
      dstPixels.byteOffset,
      dstPixels.byteOffset + dstPixels.byteLength
    );

    let opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: w, height: h },
      alphaType: srcAlphaType
    };

    return image.createPixelMapSync(arrayBuffer, opts);
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


