import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { ApiService } from '../network/ApiService';
import { DownloadService, ChapterDownloadInfo } from '../network/DownloadService';
import { CacheManager } from '../common/CacheManager';
import { PhotoViewModel, AlbumViewModel } from '../models/Album';
import { ComicAlbum, detailFromAlbum } from '../models/ComicAlbum';
import { AlbumDao } from '../storage/AlbumDao';
import { JmAlbumDetail, JmPhotoInfo, JmTagInfo, JmRelatedWork,
  JmAlbumSeries, CategoryBean, FavoriteAlbumItem,
} from '../models/dto/ApiDto';
import { navPush, navPop, navReplace } from '../common/NavHelper';
import { AlbumDetailParams, ImageViewerParams, SearchPageParams, CommentPageParams } from '../common/RouteParams';

interface SeriesItem {
  id: number;
  name: string;
}

interface ChapterRouteInfo {
  photoId: string;
  photoName: string;
}

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
  /** 下拉刷新指示器：用户显式拉取，与首屏 isLoading 分开 */
  @State isRefreshing: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  @StorageProp('isLoggedIn') isLoggedIn: boolean = false;
  @State hasRead: boolean = false;
  /** 首次使用下载功能时的引导半模态 */
  @State showDownloadGuideSheet: boolean = false;
  private lastReadChapterId: string = '';
  private albumId: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private cacheManager: CacheManager | null = null;
  private favCheckedId: number = -1; // 已经做过二次校验的 albumId，避免重复请求
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;

  // NavDestination 标准入口：参数与数据加载移入 onReady（原 router.getParams 时代在 aboutToAppear）
  private async onPageReady(ctx: NavDestinationContext): Promise<void> {
    let params = ctx.pathInfo.param as AlbumDetailParams | null;
    if (params) {
      this.albumId = params.albumId;
      this.albumName = params.albumName || '详情';
    }
    this.cacheManager = await CacheManager.getInstance();
    this.loadDetail();
  }

  // 每次页面显示（含子页 pop 返回）时重新校验收藏/已读状态，经 .onShown 绑定
  onPageShow(): void {
    // 每次页面显示时重新校验收藏状态和已读状态
    if (this.isLoggedIn && this.album) {
      this.verifyFavorited();
    }
    if (this.chapters.length > 0) {
      this.loadReadStatus();
    }
  }

  /** 详情页渲染的实体 → DTO + 章节视图模型（唯一渲染入口，网络响应不直接进页面） */
  private renderAlbum(album: ComicAlbum): void {
    this.album = detailFromAlbum(album);
    let chapters: PhotoViewModel[] = [];
    if (album.chapters.length > 0) {
      for (let chapter of album.chapters) {
        let vm = new PhotoViewModel();
        vm.id = chapter.id;
        vm.photoId = chapter.photoId;
        vm.name = chapter.title;
        vm.index = chapter.sort;
        vm.scrambleId = 0;
        chapters.push(vm);
      }
    } else {
      // 单本漫画：无 chapters，用 albumId 作为唯一章节
      let vm = new PhotoViewModel();
      vm.id = album.id;
      vm.photoId = album.id.toString();
      vm.name = '第1话';
      vm.index = 1;
      vm.scrambleId = 0;
      chapters.push(vm);
    }
    this.chapters = chapters;
    this.albumName = album.title;
    this.isFavorited = album.isFavorite;
    // 检查已读章节
    this.loadReadStatus();
    // 已登录时，用收藏列表做二次确认（详情API的is_favorite不可靠）
    if (this.isLoggedIn && !this.isFavorited) {
      this.verifyFavorited();
    }
  }

  async loadDetail(force: boolean = false): Promise<void> {
    try {
      // 1. 本地优先：有章节目录就先渲染，过期才后台刷新
      let local = await AlbumDao.load(this.albumId);
      let hasLocal = local !== null && local.chapters.length > 0;
      if (local !== null) {
        this.renderAlbum(local);
      }
      this.isLoading = local === null;
      // fetchedAt === 0 表示统计与关联推荐从未拉过（清过缓存 / 老版本升级），
      // 此时本地必然没有 related，补一次联网，不等 TTL 到期
      let relatedMissing = local !== null && local.fetchedAt === 0;
      if (!force && hasLocal && local !== null && !relatedMissing
        && Date.now() - local.updatedAt <= CacheManager.feedTtlMsOf(CacheManager.REFRESH_DETAIL)) {
        return;
      }
      // 2. 本地缺失（或过期）才走网络
      let resp = await this.apiService.getAlbumDetail(this.albumId);
      if (resp.code === 200 && resp.data) {
        // 3. 先落库，再从库读回来渲染
        await AlbumDao.saveFromDetail(resp.data as JmAlbumDetail);
        let stored = await AlbumDao.load(this.albumId);
        if (stored !== null) {
          this.renderAlbum(stored);
        }
      }
    } catch (err) {
      console.error('loadDetail error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 下拉刷新：跳过 TTL 直接重拉详情，并让收藏态重新做一次二次校验。
   * 详情不整页清空，旧内容留在屏幕上直到新数据落库后替换。
   */
  private async pullRefresh(): Promise<void> {
    if (this.isPulling) {
      this.isRefreshing = false;
      return;
    }
    this.isPulling = true;
    try {
      this.favCheckedId = -1;
      await this.loadDetail(true);
    } catch (err) {
      console.error('[AlbumDetailPage] pull refresh error:', JSON.stringify(err));
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
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
        if (found !== this.isFavorited) {
          this.isFavorited = found;
          // 校验结果写回库，避免下次读库时被旧值覆盖
          await AlbumDao.setFavorite(this.albumId, found);
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
    navPush('ImageViewerPage', {
      photoId: photo.photoId,
      photoName: photo.name,
      scrambleId: photo.scrambleId,
      albumId: this.albumId,
      albumName: this.albumName,
      chaptersStr: JSON.stringify(chapters),
      currentChapterIndex: currentIndex >= 0 ? currentIndex : 0
    } as ImageViewerParams);
  }

  async onToggleFavorite(): Promise<void> {
    if (this.favLoading) return;
    if (!this.apiService.isLoggedIn()) {
      try {
        this.showToast('请先登录后再收藏');
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
        // 收藏态写回库（详情页读库渲染，内存改了库不改会被旧值覆盖）
        await AlbumDao.setFavorite(this.albumId, this.isFavorited);
        // 收藏列表的本地分页随之作废，下次进入重新联网
        await AlbumDao.clearFeedPrefix('fav:');
      }
    } catch (err) {
      console.error('[AlbumDetailPage] toggleFavorite error:', JSON.stringify(err));
    } finally {
      this.favLoading = false;
    }
  }

  onBack(): void {
    navPop();
  }

  /** Toast 统一走 UIContext 形态（开发规范 §5.5，禁模块级 promptAction 直呼） */
  private showToast(message: string, duration: number = 2000): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: duration });
  }

  parseAuthorList(author: string | string[]): string[] {
    if (Array.isArray(author)) {
      return author;
    }
    return author ? [author] : [];
  }

  /** 加入下载队列：整本所有章节；首次使用时弹引导说明「后台下载 + 手动导出保存」流程 */
  async onDownload(): Promise<void> {
    if (this.chapters.length === 0) {
      this.showToast('暂无章节可下载');
      return;
    }
    try {
      let svc = await DownloadService.getInstance();
      let chapterList: ChapterDownloadInfo[] = this.chapters.map((ch): ChapterDownloadInfo => {
        return { photoId: ch.photoId, photoName: ch.name, scrambleId: ch.scrambleId } as ChapterDownloadInfo;
      });
      let added = svc.addAlbumTasks(this.albumId, this.albumName, chapterList);
      if (added === 0) {
        this.showToast('全部章节已在下载队列中', 2500);
      } else {
        this.showToast(`已加入 ${added} 个章节到下载队列`, 2500);
      }

      let cache = await CacheManager.getInstance();
      if (!cache.getDownloadGuideShown()) {
        cache.setDownloadGuideShown();
        this.showDownloadGuideSheet = true;
        return;
      }
      navPush('DownloadPage');
    } catch (e) {
      console.error('[AlbumDetailPage] download error:', JSON.stringify(e));
      this.showToast('加入下载队列失败');
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
      this.showToast('已复制到剪贴板', 2500);
    } catch (e) {
      console.error('[AlbumDetailPage] shareFallback error:', JSON.stringify(e));
      this.showToast('分享失败');
    }
  }

  formatAuthor(author: string | string[]): string {
    if (Array.isArray(author)) {
      return author.join(', ');
    }
    return author || '';
  }

  /** 首次下载引导行 */
  @Builder
  GuideRow(text: string) {
    Row() {
      Circle()
        .width(5)
        .height(5)
        .fill($r('app.color.brand'))
        .margin({ top: 9 })

      Text(text)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(22)
        .margin({ left: 10 })
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 10 })
  }

  /** 首次下载引导半模态：说明「后台下载 + 手动到下载管理页导出保存」流程 */
  @Builder
  DownloadGuideSheetBuilder() {
    Column() {
      Text('下载说明')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Column() {
        this.GuideRow('章节已加入后台下载队列，可继续浏览其他漫画，进度在通知栏与下载管理页展示')
        this.GuideRow('全部章节下载完成后会收到系统通知提醒')
        this.GuideRow('保存压缩包需到「下载管理」页点击「导出压缩包」，自行选择保存位置（导出不会自动进行）')
      }
      .width('100%')
      .margin({ top: 14 })
      .alignItems(HorizontalAlign.Start)

      Row() {
        Button('知道了')
          .height(40)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.bg_secondary'))
          .borderRadius(20)
          .padding({ left: 20, right: 20 })
          .onClick(() => {
            this.showDownloadGuideSheet = false;
          })

        Button('前往下载管理页')
          .height(40)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_on_accent'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(20)
          .padding({ left: 20, right: 20 })
          .margin({ left: 12 })
          .onClick(() => {
            this.showDownloadGuideSheet = false;
            navPush('DownloadPage');
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 20 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 24 + this.bottomSafeHeight })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
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
        Refresh({ refreshing: $$this.isRefreshing }) {
        Scroll() {
          Column() {
            // ── 顶部留白（避开浮层顶栏） ──
            Row().height(this.topSafeHeight + 48)

            // ── 基本信息区 ──
            Row() {
              // 封面
              Image(this.apiService.coverSource(this.album.id, '', this.album.image))
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
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
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
                        navPush('SearchPage', { keyword: tag } as SearchPageParams);
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
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .backgroundColor($r('app.color.brand_bg_strong'))
                      .borderRadius(4)
                      .border({ width: 0.5, color: $r('app.color.brand_border') })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (name) {
                          navPush('SearchPage', { keyword: name } as SearchPageParams);
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
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .backgroundColor($r('app.color.brand_bg_strong'))
                      .borderRadius(4)
                      .border({ width: 0.5, color: $r('app.color.brand_border') })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (actor) {
                          navPush('SearchPage', { keyword: actor } as SearchPageParams);
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
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .backgroundColor($r('app.color.brand_bg_strong'))
                      .borderRadius(4)
                      .border({ width: 0.5, color: $r('app.color.brand_border') })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (work) {
                          navPush('SearchPage', { keyword: work } as SearchPageParams);
                        }
                      })
                  }, (work: string) => work)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            }

            // ── 开始阅读 + 评论 + 下载 按钮 ──
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
                    navPush('AlbumCommentPage',
                      { albumId: this.albumId, albumName: this.albumName } as CommentPageParams);
                  })

                Button('下载')
                  .height(48)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.brand'))
                  .backgroundColor($r('app.color.bg_card'))
                  .borderRadius(24)
                  .border({ width: 1, color: $r('app.color.brand') })
                  .padding({ left: 24, right: 24 })
                  .margin({ left: 12 })
                  .onClick(() => this.onDownload())
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
                    Image(this.apiService.coverSource(work.id, '', work.image))
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
                    navReplace('AlbumDetailPage', { albumId: work.id, albumName: work.name } as AlbumDetailParams);
                  })
                })
              }
              .width('100%')
            }

            // 底部占位：避让导航条区域，防止最后一项被手势指示条遮挡
            Column().height(this.bottomSafeHeight + 24)
          }
          .width('100%')
          // 内容不足一屏时撑满视口并顶部对齐：否则 Scroll 会把矮内容垂直居中
          .constraintSize({ minHeight: '100%' })
          .justifyContent(FlexAlign.Start)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        }
        .onRefreshing(() => {
          this.pullRefresh();
        })
        .width('100%')
        .height('100%')
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
        // 左：返回按钮（40×40 标准点击体：裸 SymbolGlyph 字形有效宽度仅约 13~24vp，不达 24vp 规范）
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .onClick(() => this.onBack())

        Blank()

        // 右：分享（同左，40×40 点击体）
        Stack() {
          SymbolGlyph($r('sys.symbol.share'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .onClick(() => this.onShare())
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 12, right: 12, top: this.topSafeHeight + 4, bottom: 4 })
      .backgroundColor($r('app.color.header_bg'))
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
    .bindSheet(this.showDownloadGuideSheet!!, this.DownloadGuideSheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: true,
      preferType: SheetType.BOTTOM
    })
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.onPageReady(ctx);
    })
    .onShown(() => this.onPageShow())
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function AlbumDetailPageBuilder() {
  AlbumDetailPage();
}
