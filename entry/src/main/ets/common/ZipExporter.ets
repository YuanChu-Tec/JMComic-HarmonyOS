import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { DownloadService } from '../network/DownloadService';
import { ComicLibrary } from './ComicLibrary';

/** 批量导出的专辑引用（下载管理页构建） */
export interface AlbumExportRef {
  albumId: number;
  albumName: string;
}

/**
 * 下载内容 zip 导出器
 *
 * 将统一图片仓库中的专辑目录（filesDir/JMComic/library/{专辑名}_{专辑ID}）用
 * zlib.compressFile 整目录打包（zip 内保留「章节/序号」层级），再经 DocumentViewPicker.save 由用户
 * 选择保存位置——系统文件保存对话框无需申请任何存储权限。
 *
 * 支持单专辑导出与多专辑批量导出（一次保存对话框返回多个 URI，逐个复制落盘）。
 * 临时 zip 统一放在 cacheDir/zip_export 下，导出后清理。
 */
export class ZipExporter {
  /** 单专辑导出：成功返回提示文案；用户在保存对话框取消时返回 null */
  static async exportAlbum(context: common.UIAbilityContext,
    albumId: number, albumName: string): Promise<string | null> {
    let safeName = DownloadService.sanitizeFileName(albumName);
    let zipPath = await ZipExporter.buildAlbumZip(context, albumId, albumName, `${safeName}.zip`);
    try {
      let opts: picker.DocumentSaveOptions = {
        newFileNames: [`${safeName}.zip`]
      };
      let documentPicker = new picker.DocumentViewPicker(context);
      let uris = await documentPicker.save(opts);
      if (!uris || uris.length === 0) {
        return null;
      }
      ZipExporter.copyToUri(zipPath, uris[0]);
      // 导出时间由调用方写 pref（exported_{albumId}），清理规则据此判断；
      // 章节清单只记磁盘事实，不再存导出时间
      return `压缩包已保存：${safeName}.zip`;
    } finally {
      ZipExporter.cleanupZip(zipPath);
    }
  }

  /**
   * 批量导出：逐专辑打包临时 zip 后，用一次保存对话框让用户选择位置
   * @param albums 待导出专辑列表（调用方保证每个专辑目录已有内容）
   * @returns 成功返回提示文案；用户在保存对话框取消时返回 null
   */
  static async exportAlbums(context: common.UIAbilityContext,
    albums: AlbumExportRef[]): Promise<string | null> {
    let svc = await DownloadService.getInstance();
    let zipPaths: string[] = [];
    let fileNames: string[] = [];
    let usedNames: Set<string> = new Set();
    try {
      for (let a of albums) {
        let safeName = DownloadService.sanitizeFileName(a.albumName);
        // 同名专辑批量导出时文件名追加 ID 区分
        let finalName = safeName;
        if (usedNames.has(`${finalName}.zip`)) {
          finalName = `${safeName}_${a.albumId}`;
        }
        usedNames.add(`${finalName}.zip`);

        let zipPath = await ZipExporter.buildAlbumZip(context, a.albumId, a.albumName, `${finalName}_${a.albumId}.zip`);
        zipPaths.push(zipPath);
        fileNames.push(`${finalName}.zip`);
      }

      let opts: picker.DocumentSaveOptions = {
        newFileNames: fileNames
      };
      let documentPicker = new picker.DocumentViewPicker(context);
      let uris = await documentPicker.save(opts);
      if (!uris || uris.length === 0) {
        return null;
      }
      let saved = 0;
      for (let i = 0; i < uris.length && i < zipPaths.length; i++) {
        ZipExporter.copyToUri(zipPaths[i], uris[i]);
        saved++;
      }
      return `已保存 ${saved} 个压缩包`;
    } finally {
      for (let z of zipPaths) {
        ZipExporter.cleanupZip(z);
      }
    }
  }

  /** 打包专辑当前版本图片为临时 zip（cacheDir/zip_export 下，唯一文件名防并发覆盖） */
  private static async buildAlbumZip(context: common.UIAbilityContext,
    albumId: number, albumName: string, zipFileName: string): Promise<string> {
    let library = await ComicLibrary.getInstance();
    let stageDir = `${context.cacheDir}/zip_export`;
    if (!fileIo.accessSync(stageDir)) {
      fileIo.mkdirSync(stageDir, true);
    }
    // 从版本化仓库构建扁平 staging：{章节}/{序号}.png
    let albumStage = `${stageDir}/stage_${albumId}_${zipFileName}`;
    let chapters = await library.buildExportStage(albumId, albumName, albumStage);
    if (chapters === 0) {
      throw new Error('专辑下载内容为空');
    }

    let zipPath = `${stageDir}/${zipFileName}`;
    if (fileIo.accessSync(zipPath)) {
      fileIo.unlinkSync(zipPath);
    }

    let opts: zlib.Options = {
      // 内容均为 PNG（本身已是压缩格式），再跑 deflate 压缩率≈0 却耗时数分钟；
      // 用存储模式（level 0）把打包时间降到 I/O 级
      level: zlib.CompressLevel.COMPRESS_LEVEL_NO_COMPRESSION
    };
    // 整目录打包：zip 内保留「章节名/序号.png」层级
    await zlib.compressFile(albumStage, zipPath, opts);
    await fileIo.rmdir(albumStage);
    return zipPath;
  }

  /** 复制临时 zip 到用户在保存对话框中选定的 URI（picker URI 须以 openSync 打开授权后按 fd 复制，勿直接当路径用） */
  private static copyToUri(zipPath: string, uri: string): void {
    let src = fileIo.openSync(zipPath, fileIo.OpenMode.READ_ONLY);
    let dst = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE);
    try {
      fileIo.copyFileSync(src.fd, dst.fd);
    } finally {
      fileIo.closeSync(src);
      fileIo.closeSync(dst);
    }
  }

  private static cleanupZip(zipPath: string): void {
    try {
      if (fileIo.accessSync(zipPath)) {
        fileIo.unlinkSync(zipPath);
      }
    } catch (_e) {
      // 清理失败不影响导出结果
    }
  }
}
