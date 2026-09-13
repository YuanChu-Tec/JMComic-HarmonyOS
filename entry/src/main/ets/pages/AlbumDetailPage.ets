import { router, promptAction } from '@kit.ArkUI';
import { common, wantAgent } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { pasteboard, zlib } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { ApiService } from '../network/ApiService';
import { CacheManager } from '../common/CacheManager';
import { DownloadManager, ChapterDownloadInfo } from '../common/DownloadManager';
import {
  JmAlbumDetail,
  JmPhotoInfo,
  PhotoViewModel,
  JmTagInfo,
  JmRelatedWork,
  AlbumViewModel,
  JmAlbumSeries,
  CategoryBean,
  FavoriteAlbumItem
} from '../models/Album';

interface RouterParams {
  albumId: number;
  albumName: string;
}

interface SeriesItem {
  id: number;
  name: string;
}

interface ChapterRouteInfo {
  photoId: string;
  photoName: string;
}

@Entry
@Component
struct AlbumDetailPage {
  @State album: JmAlbumDetail | null = null;
  @State chapters: PhotoViewModel[] = [];
  @State isLoading: boolean = true;
  @State albumName: string = '详情';
  @State isChapterExpanded: boolean = false;
  @State isFavorited: boolean = false;
  @State favLoading: boolean = false;
  @State refreshTrigger: number = 0;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  @StorageProp('isLoggedIn') isLoggedIn: boolean = false;
  @State hasRead: boolean = false;
  @State isDownloading: boolean = false;
  private lastReadChapterId: string = '';
  private downloadNotifId: number = 0;
  private downloadMgr: DownloadManager | null = null;
  private albumId: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private cacheManager: CacheManager | null = null;
  private favCheckedId: number = -1; // 已经做过二次校验的 albumId，避免重复请求

  async aboutToAppear(): Promise<void> {
    let params = router.getParams() as RouterParams;
    if (params) {
      this.albumId = params.albumId;
      this.albumName = params.albumName || '详情';
    }
    this.cacheManager = await CacheManager.getInstance();
    this.loadDetail();
  }

  onPageShow(): void {
    // 每次页面显示时重新校验收藏状态和已读状态
    if (this.isLoggedIn && this.album) {
      this.verifyFavorited();
    }
    if (this.chapters.length > 0) {
      this.loadReadStatus();
    }
  }

  async loadDetail(): Promise<void> {
    this.isLoading = true;
    try {
      let resp = await this.apiService.getAlbumDetail(this.albumId);

      if (resp.code === 200 && resp.data) {
        this.album = resp.data as JmAlbumDetail;
        if (this.album) {
          // series 包含章节列表，每项为 {id, name, sort}
          let series = this.album.series;
          if (series && series.length > 0) {
            this.chapters = series.map((ep: JmAlbumSeries, index: number) => {
              let vm = new PhotoViewModel();
              vm.id = typeof ep.id === 'number' ? ep.id : parseInt(ep.id) || 0;
              vm.photoId = ep.id?.toString() || '';
              vm.name = ep.name || '';
              vm.index = typeof ep.sort === 'number' ? ep.sort : parseInt(ep.sort) || (index + 1);
              vm.scrambleId = 0;
              return vm;
            });
          } else {
            // 单本漫画：无 series，用 albumId 作为唯一章节
            let vm = new PhotoViewModel();
            vm.id = this.albumId;
            vm.photoId = this.albumId.toString();
            vm.name = '第1话';
            vm.index = 1;
            vm.scrambleId = 0;
            this.chapters = [vm];
          }
          this.albumName = this.album.name;
          this.isFavorited = this.album.is_favorite === true;
          // 检查已读章节
          this.loadReadStatus();
          // 已登录时，用收藏列表做二次确认（详情API的is_favorite不可靠）
          if (this.isLoggedIn && !this.isFavorited) {
            this.verifyFavorited();
          }
        }
      }
    } catch (err) {
      console.error('loadDetail error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 检查已读章节
   */
  loadReadStatus(): void {
    if (!this.cacheManager) return;
    let anyRead = false;
    for (let ch of this.chapters) {
      ch.isRead = this.cacheManager.isChapterRead(this.albumId, ch.photoId);
      if (ch.isRead) anyRead = true;
    }
    this.hasRead = anyRead;
    this.lastReadChapterId = this.cacheManager.getLastReadChapterId(this.albumId) || '';
    this.chapters = [...this.chapters];
    this.refreshTrigger++;
  }

  /**
   * 二次校验收藏状态：跳过详情API不可靠的 is_favorite 字段，
   * 直接查询收藏列表确认当前漫画是否已收藏
   */
  async verifyFavorited(): Promise<void> {
    if (this.favCheckedId === this.albumId) return;
    this.favCheckedId = this.albumId;
    try {
      // 查第一页全部收藏，判断当前album是否在列表中
      let resp = await this.apiService.getFavorites(1, '0');
      if (resp.code === 200 && resp.data && resp.data.list) {
        let found = resp.data.list.some((item: FavoriteAlbumItem) => {
          return String(item.id) === String(this.albumId);
        });
        if (found) {
          this.isFavorited = true;
        }
      }
    } catch (err) {
      console.error('[AlbumDetailPage] verifyFavorited error:', JSON.stringify(err));
    }
  }

  onChapterClick(photo: PhotoViewModel): void {
    let chapters: ChapterRouteInfo[] = this.chapters.map((ch) => {
      return { photoId: ch.photoId, photoName: ch.name } as ChapterRouteInfo;
    });
    let currentIndex = this.chapters.findIndex(ch => ch.photoId === photo.photoId);
    router.pushUrl({
      url: 'pages/ImageViewerPage',
      params: {
        photoId: photo.photoId,
        photoName: photo.name,
        scrambleId: photo.scrambleId,
        albumId: this.albumId,
        albumName: this.albumName,
        chaptersStr: JSON.stringify(chapters),
        currentChapterIndex: currentIndex >= 0 ? currentIndex : 0
      }
    });
  }

  async onToggleFavorite(): Promise<void> {
    if (this.favLoading) return;
    if (!this.apiService.isLoggedIn()) {
      try {
        await promptAction.showToast({ message: '请先登录后再收藏', duration: 2000 });
      } catch (e) {
        console.error('[AlbumDetailPage] showToast error:', JSON.stringify(e));
      }
      return;
    }
    this.favLoading = true;
    try {
      let result = await this.apiService.toggleFavorite(this.albumId.toString());
      if (result.status === 'ok') {
        this.isFavorited = !this.isFavorited;
      }
    } catch (err) {
      console.error('[AlbumDetailPage] toggleFavorite error:', JSON.stringify(err));
    } finally {
      this.favLoading = false;
    }
  }

  onBack(): void {
    router.back();
  }

  parseAuthorList(author: string | string[]): string[] {
    if (Array.isArray(author)) {
      return author;
    }
    return author ? [author] : [];
  }

  async onDownload(): Promise<void> {
    if (this.chapters.length === 0) {
      try { promptAction.showToast({ message: '暂无章节可下载', duration: 2000 }); } catch (_e) {}
      return;
    }

    let context = getContext() as common.UIAbilityContext;
    let baseDir = `${context.filesDir}/JMComic`;

    this.downloadNotifId = this.albumId + 10000;

    try {
      // 初始化 wantAgent（点击通知打开应用）
      await this.ensureWantAgent();
      // 发布初始通知
      this.publishNotif(0, 100, '准备下载...');

      this.isDownloading = true;

      let chapterList: ChapterDownloadInfo[] = this.chapters.map((ch): ChapterDownloadInfo => {
        return { photoId: ch.photoId, photoName: ch.name, scrambleId: ch.scrambleId } as ChapterDownloadInfo;
      });

      let mgr = await DownloadManager.getInstance();
      this.downloadMgr = mgr;
      await mgr.downloadAlbum(
        this.albumName,
        chapterList,
        baseDir,
        (current: number, total: number, chapterName: string) => {
          console.info(`[AlbumDetailPage] download progress: ${current}/${total}`);
          this.publishNotif(current, total, chapterName);
        },
        async (success: number, failed: number) => {
          this.isDownloading = false;
          this.publishDoneNotif(success, failed);
          let msg = failed > 0
            ? `下载完成：${success}张成功，${failed}张失败`
            : `下载完成：共${success}张`;
          try { promptAction.showToast({ message: msg, duration: 5000 }); } catch (_e) {}

          // 下载完成后打包为 zip 并导出到公共目录
          await this.exportAsZip(context, baseDir);
        },
        (msg: string) => {
          this.isDownloading = false;
          this.publishErrorNotif(msg);
          try { promptAction.showToast({ message: `下载失败：${msg}`, duration: 3000 }); } catch (_e) {}
        }
      );
    } catch (e) {
      this.isDownloading = false;
      console.error('[AlbumDetailPage] download error:', JSON.stringify(e));
      try { promptAction.showToast({ message: '下载失败', duration: 2000 }); } catch (_e) {}
    }
  }

  /**
   * 收集目录下所有文件（递归）
   */
  private async collectFiles(dirPath: string): Promise<string[]> {
    let result: string[] = [];
    let names = await fileIo.listFile(dirPath);
    for (let name of names) {
      let fullPath = dirPath + '/' + name;
      let stat = fileIo.statSync(fullPath);
      if (stat.isDirectory()) {
        let sub = await this.collectFiles(fullPath);
        result.push(...sub);
      } else {
        result.push(fullPath);
      }
    }
    return result;
  }

  /**
   * 打包为 zip 并通过 DocumentViewPicker 保存到公共目录
   */
  private async exportAsZip(context: common.UIAbilityContext, baseDir: string): Promise<void> {
    try {
      let safeName = this.albumName.replace(/[\/\\:*?"<>|]/g, '_').trim();
      let albumDir = `${baseDir}/${safeName}`;

      if (!fileIo.accessSync(albumDir)) {
        return; // 目录不存在，跳过
      }

      let allFiles = await this.collectFiles(albumDir);
      if (allFiles.length === 0) {
        return;
      }

      let zipPath = `${baseDir}/${safeName}.zip`;
      // 删除旧 zip
      if (fileIo.accessSync(zipPath)) {
        fileIo.unlinkSync(zipPath);
      }

      // 使用 @ohos.zlib.compressFiles 打包多文件为 zip
      await zlib.compressFiles(allFiles, zipPath, {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
      });

      // 用 DocumentViewPicker 保存 zip 到公共目录
      let documentPicker = new picker.DocumentViewPicker(context);
      let uris = await documentPicker.save({
        newFileNames: [`${safeName}.zip`]
      });

      if (uris && uris.length > 0) {
        // 复制到用户选择的目录
        fileIo.copyFileSync(zipPath, uris[0]);
        try {
          promptAction.showToast({
            message: `压缩包已保存到 Download/${safeName}.zip (${allFiles.length}张)`,
            duration: 5000
          });
        } catch (_e) {}
      }

      // 清理临时 zip
      try { fileIo.unlinkSync(zipPath); } catch (_e) {}
    } catch (e) {
      console.error('[AlbumDetailPage] zip export error:', JSON.stringify(e));
      try {
        promptAction.showToast({ message: `打包完成，但导出失败：${JSON.stringify(e)}`, duration: 3000 });
      } catch (_e) {}
    }
  }

  onCancelDownload(): void {
    if (this.downloadMgr) {
      this.downloadMgr.cancelDownload();
      this.downloadMgr = null;
    }
    this.isDownloading = false;
    try { promptAction.showToast({ message: '已取消下载', duration: 2000 }); } catch (_e) {}
  }

  private wantAgentObj: object | null = null;

  /** 初始化 wantAgent（点击通知打开应用） */
  private async ensureWantAgent(): Promise<object> {
    if (this.wantAgentObj) {
      return this.wantAgentObj;
    }
    let context = getContext() as common.UIAbilityContext;
    let abilityName = context.abilityInfo.name;
    let info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: abilityName
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
    };
    this.wantAgentObj = await wantAgent.getWantAgent(info);
    return this.wantAgentObj;
  }

  private publishNotif(current: number, total: number, chapterName: string): void {
    let percent = total > 0 ? Math.round(current / total * 100) : 0;
    try {
      let template: notificationManager.NotificationTemplate = {
        name: 'downloadTemplate',
        data: {
          progressValue: current,
          progressMaxValue: total,
          isProgressIndeterminate: false
        }
      };
      let notifReq: notificationManager.NotificationRequest = {
        id: this.downloadNotifId,
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        template: template,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: `JMComic - ${this.albumName}`,
            text: chapterName,
            additionalText: `${percent}% (${current}/${total})`
          }
        },
        wantAgent: this.wantAgentObj as Record<string, Object>
      };
      notificationManager.publish(notifReq).catch(() => {});
    } catch (e) {
      console.error('[AlbumDetailPage] publish notif error:', JSON.stringify(e));
    }
  }

  private publishDoneNotif(success: number, failed: number): void {
    try {
      let msg = failed > 0
        ? `下载完成：${success}张成功，${failed}张失败`
        : `下载完成：共${success}张`;
      let template: notificationManager.NotificationTemplate = {
        name: 'downloadTemplate',
        data: {
          progressValue: success,
          progressMaxValue: success + failed,
          isProgressIndeterminate: false
        }
      };
      let notifReq: notificationManager.NotificationRequest = {
        id: this.downloadNotifId,
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        template: template,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'JMComic - 下载完成',
            text: msg,
            additionalText: '100%'
          }
        },
        wantAgent: this.wantAgentObj as Record<string, Object>
      };
      notificationManager.publish(notifReq).catch(() => {});
    } catch (e) {
      console.error('[AlbumDetailPage] publish done notif error:', JSON.stringify(e));
    }
  }

  private publishErrorNotif(msg: string): void {
    try {
      let notifReq: notificationManager.NotificationRequest = {
        id: this.downloadNotifId,
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'JMComic - 下载失败',
            text: msg,
            additionalText: '失败'
          }
        },
        wantAgent: this.wantAgentObj as Record<string, Object>
      };
      notificationManager.publish(notifReq).catch(() => {});
    } catch (e) {
      console.error('[AlbumDetailPage] publish error notif:', JSON.stringify(e));
    }
  }

  onShare(): void {
    let shareText = `JM${this.albumId} ${this.albumName} - 来自 JMComic`;
    try {
      let context = getContext() as common.UIAbilityContext;
      let data = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content: shareText
      });
      let controller = new systemShare.ShareController(data);
      controller.show(context, {});
      console.info('[AlbumDetailPage] share sheet shown');
    } catch (e) {
      console.error('[AlbumDetailPage] share error:', JSON.stringify(e));
      this.shareFallback(shareText);
    }
  }

  private shareFallback(text: string): void {
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      let pb = pasteboard.getSystemPasteboard();
      pb.setData(data);
      promptAction.showToast({ message: '已复制到剪贴板', duration: 2500 });
    } catch (e) {
      console.error('[AlbumDetailPage] shareFallback error:', JSON.stringify(e));
      promptAction.showToast({ message: '分享失败', duration: 2000 });
    }
  }

  formatAuthor(author: string | string[]): string {
    if (Array.isArray(author)) {
      return author.join(', ');
    }
    return author || '';
  }

  build() {
    Stack() {
      // ── 全屏内容 ──
      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('app.color.brand'))
          Text('加载中...')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.album) {
        Scroll() {
          Column() {
            // ── 顶部留白（避开浮层顶栏） ──
            Row().height(this.topSafeHeight + 48)

            // ── 基本信息区 ──
            Row() {
              // 封面
              Image(this.apiService.buildCoverUrl(this.album.id, ''))
                .width(120)
                .height(165)
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
                .backgroundColor($r('app.color.bg_secondary'))

              Column() {
                Text(this.album.name)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .lineHeight(24)

                Row() {
                  if (this.album.category && typeof this.album.category === 'object') {
                    Text((this.album.category as CategoryBean).title || '')
                      .fontSize(12)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor($r('app.color.brand_bg'))
                      .borderRadius(4)
                      .margin({ right: 8 })
                  }
                }
                .width('100%')
                .margin({ top: 8 })

                Row() {
                  Text(`👁 ${this.album.total_views}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ right: 16 })

                  Text(`📷 ${this.chapters.length}话`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ right: 16 })

                  Text(`❤ ${this.album.likes}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ right: 16 })

                  Text(`💬 ${this.album.comment_total || 0}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .width('100%')
                .margin({ top: 8 })

                Text('禁漫车')
                  .fontSize(14)
                  .fontColor($r('app.color.text_tertiary'))
                Text(`JM${this.album.id}`)
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))

                // 收藏按钮
                Button({ type: ButtonType.Normal }) {
                  Row() {
                    SymbolGlyph($r('sys.symbol.heart'))
                      .fontSize(16)
                      .fontColor([$r('app.color.brand')])
                    Text(this.isFavorited ? '已收藏' : '收藏')
                      .fontSize(13)
                      .fontColor($r('app.color.brand'))
                      .margin({ left: 4 })
                  }
                }
                .backgroundColor(this.isFavorited ? $r('app.color.brand_checked') : $r('app.color.brand_bg'))
                .borderRadius(16)
                .height(32)
                .padding({ left: 16, right: 16 })
                .margin({ top: 8 })
                .onClick(() => this.onToggleFavorite())
              }
              .layoutWeight(1)
              .height(185)
              .margin({ left: 16 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding(16)

            // 描述
            if (this.album.description && this.album.description.length > 0) {
              Column() {
                Text('简介')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .margin({ bottom: 8 })

                Text(this.album.description)
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                  .lineHeight(22)
                  .maxLines(6)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 16 })
              .alignItems(HorizontalAlign.Start)
            }

            // 标签
            if (this.album.tags && this.album.tags.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.album.tags, (tag: string) => {
                  Text(tag)
                    .fontSize(12)
                    .fontColor($r('app.color.brand'))
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .backgroundColor($r('app.color.brand_bg_strong'))
                    .borderRadius(4)
                    .border({ width: 0.5, color: $r('app.color.brand_border') })
                    .margin({ right: 8, bottom: 8 })
                    .onClick(() => {
                      if (tag) {
                        router.pushUrl({
                          url: 'pages/SearchPage',
                          params: { keyword: tag }
                        });
                      }
                    })
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 4 })
            }

            // 作者
            if (this.parseAuthorList(this.album?.author ?? '').length > 0) {
              Column() {
                Text('作者')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .margin({ bottom: 6 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.parseAuthorList(this.album?.author ?? ''), (name: string) => {
                    Text(name)
                      .fontSize(12)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor($r('app.color.brand_bg_strong'))
                      .borderRadius(4)
                      .border({ width: 0.5, color: $r('app.color.brand_border') })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (name) {
                          router.pushUrl({
                            url: 'pages/SearchPage',
                            params: { keyword: name }
                          });
                        }
                      })
                  }, (name: string) => name)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            }

            // 登场人物
            if (this.album.actors && this.album.actors.length > 0) {
              Column() {
                Text('登场人物')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .margin({ bottom: 6 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.album.actors, (actor: string) => {
                    Text(actor)
                      .fontSize(12)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor($r('app.color.brand_bg_strong'))
                      .borderRadius(4)
                      .border({ width: 0.5, color: $r('app.color.brand_border') })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (actor) {
                          router.pushUrl({
                            url: 'pages/SearchPage',
                            params: { keyword: actor }
                          });
                        }
                      })
                  }, (actor: string) => actor)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            }

            // 作品（该漫画所属的作品/IP）
            if (this.album.works && this.album.works.length > 0) {
              Column() {
                Text('作品')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .margin({ bottom: 6 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.album.works, (work: string) => {
                    Text(work)
                      .fontSize(12)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor($r('app.color.brand_bg_strong'))
                      .borderRadius(4)
                      .border({ width: 0.5, color: $r('app.color.brand_border') })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (work) {
                          router.pushUrl({
                            url: 'pages/SearchPage',
                            params: { keyword: work }
                          });
                        }
                      })
                  }, (work: string) => work)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            }

            // ── 开始阅读 + 评论 按钮 ──
            if (this.chapters.length > 0) {
              Row() {
                Button(this.hasRead && this.chapters.length > 1 ? '继续阅读' : '开始阅读')
                  .layoutWeight(1)
                  .height(48)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_on_accent'))
                  .backgroundColor($r('app.color.brand'))
                  .borderRadius(24)
                  .onClick(() => {
                    if (this.hasRead && this.lastReadChapterId) {
                      let idx = this.chapters.findIndex(ch => ch.photoId === this.lastReadChapterId);
                      if (idx >= 0) {
                        this.onChapterClick(this.chapters[idx]);
                      } else {
                        this.onChapterClick(this.chapters[0]);
                      }
                    } else {
                      this.onChapterClick(this.chapters[0]);
                    }
                  })

                Button('评论')
                  .height(48)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.brand'))
                  .backgroundColor($r('app.color.bg_card'))
                  .borderRadius(24)
                  .border({ width: 1, color: $r('app.color.brand') })
                  .padding({ left: 24, right: 24 })
                  .margin({ left: 12 })
                  .onClick(() => {
                    router.pushUrl({
                      url: 'pages/AlbumCommentPage',
                      params: { albumId: this.albumId, albumName: this.albumName }
                    });
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16 })
            }

            // ── 章节列表标题 ──
            Row() {
              Text('章节列表')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))

              Blank()

              Text(`${this.chapters.length} 章`)
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ right: 8 })

              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(16)
                .fontColor([$r('app.color.text_tertiary')])
                .rotate({ angle: this.isChapterExpanded ? 180 : 0 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 8 })
            .backgroundColor($r('app.color.bg_card_alt'))
            .onClick(() => { this.isChapterExpanded = !this.isChapterExpanded; })

            // ── 章节列表 ──
            if (this.isChapterExpanded) {
              ForEach(this.chapters, (photo: PhotoViewModel, index: number) => {
                Row() {
                  Text(`${index + 1}`)
                    .fontSize(14)
                    .fontColor($r('app.color.text_tertiary'))
                    .width(30)
                    .textAlign(TextAlign.Center)

                  Text(photo.name)
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ left: 8 })

                  if (photo.isRead) {
                    Text('看过')
                      .fontSize(11)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .backgroundColor($r('app.color.brand_bg'))
                      .borderRadius(4)
                      .margin({ right: 6 })
                  }

                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([$r('app.color.text_disabled')])
                }
                .width('100%')
                .height(52)
                .padding({ left: 16, right: 16 })
                .backgroundColor(photo.isRead ? $r('app.color.brand_bg') : $r('app.color.bg_card'))
                .onClick(() => this.onChapterClick(photo))
              }, (item: PhotoViewModel) => `${item.id}_${item.isRead}`)
            }

            // 相关作品
            if (this.album.related_list && this.album.related_list.length > 0) {
              Column() {
                Text('相关作品')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .padding({ left: 16, top: 16, bottom: 8 })
                  .backgroundColor($r('app.color.bg_card_alt'))

                ForEach(this.album.related_list, (work: JmRelatedWork) => {
                  Row() {
                    Image(this.apiService.buildCoverUrl(work.id, ''))
                      .width(60)
                      .height(80)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(4)
                      .backgroundColor($r('app.color.bg_secondary'))

                    Column() {
                      Text(work.name)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      Text(work.author)
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ top: 4 })
                    }
                    .layoutWeight(1)
                    .margin({ left: 12 })
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .backgroundColor($r('app.color.bg_card'))
                  .onClick(() => {
                    router.replaceUrl({
                      url: 'pages/AlbumDetailPage',
                      params: { albumId: work.id, albumName: work.name }
                    });
                  })
                })
              }
              .width('100%')
            }

            // 底部占位
            Column().height(20)
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
      } else {
        Column() {
          Text('加载失败')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'))
          Button('重新加载')
            .fontSize(14)
            .fontColor($r('app.color.text_on_accent'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius(18)
            .padding({ left: 24, right: 24 })
            .height(36)
            .margin({ top: 16 })
            .onClick(() => this.loadDetail())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // ── 沉浸式顶部导航栏（毛玻璃浮层） ──
      Row() {
        // 左：返回按钮
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.text_primary')])
          .onClick(() => this.onBack())

        Blank()

        // 右：分享
        SymbolGlyph($r('sys.symbol.share'))
          .fontSize(24)
          .fontColor([$r('app.color.text_primary')])
          .onClick(() => this.onShare())
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 12, right: 12, top: this.topSafeHeight + 20, bottom: 4 })
      .backgroundColor($r('app.color.header_bg'))
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
