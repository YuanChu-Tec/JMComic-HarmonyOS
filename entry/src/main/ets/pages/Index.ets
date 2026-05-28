import { router, display, promptAction } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import { AlbumViewModel, JmAlbumInfo, JmPromoteSection, SearchResultData, IAlbumViewModelJSON,
  CommentInfo, CommentPageData, parseCommentRaw,
  COMMENT_MODE_ALL, COMMENT_MODE_MANHUA, COMMENT_MODE_CHAT, COMMENT_MODE_NAME_MAP,
} from '../models/Album';
import { CacheManager } from '../common/CacheManager';
import {
  CATEGORY_ALL, CATEGORY_DOUJIN, CATEGORY_SINGLE, CATEGORY_SHORT,
  CATEGORY_ANOTHER, CATEGORY_HANMAN, CATEGORY_MEIMAN,
  CATEGORY_DOUJIN_COSPLAY, CATEGORY_3D, CATEGORY_ENGLISH_SITE,
  CATEGORY_NAME_MAP, ORDER_BY_LATEST, ORDER_MONTH_RANKING,
  ORDER_WEEK_RANKING, ORDER_DAY_RANKING, ORDER_BY_LIKE,
  ORDER_NAME_MAP
} from '../common/Constants';
import { HdsTabs, HdsTabsController, HdsTabsFloatingStyle, hdsMaterial } from '@kit.UIDesignKit';
import { MenuItem, buildMenuPopup, RouteColumn, buildRouteMenu, buildMenuOverlay } from '../common/MenuPopup';
import { CommentItemComponent } from '../common/CommentItem';

interface OrderItem {
  key: string;
  label: string;
}

interface ForumModeItem {
  key: string;
  label: string;
}

// ═══════════════════════════════════════════
// 首页 — 推荐分区横向滑动
// ═══════════════════════════════════════════
@Component
struct HomePage {
  @State sections: JmPromoteSection[] = [];
  @State isLoading: boolean = true;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  private apiService: ApiService = new ApiService();
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  async aboutToAppear(): Promise<void> {
    try {
      let resp = await this.apiService.getPromote();
      if (resp.code === 200 && resp.data) {
        this.sections = resp.data as JmPromoteSection[];
      }
    } catch (err) {
      console.error('[HomePage] getPromote error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  onAlbumClick(album: JmAlbumInfo): void {
    let id = typeof album.id === 'number' ? album.id : parseInt(album.id as string) || 0;
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: { albumId: id, albumName: album.name }
    });
  }

  build() {
    Scroll() {
      Column() {
        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#FF5A5F')
            Text('加载中...')
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 12 })
          }
          .width('100%')
          .height(300)
          .justifyContent(FlexAlign.Center)
        } else if (this.sections.length === 0) {
          Column() {
            Text('暂无数据')
              .fontSize(16)
              .fontColor('#999999')
          }
          .width('100%')
          .height(300)
          .justifyContent(FlexAlign.Center)
        } else {
          ForEach(this.sections, (section: JmPromoteSection) => {
            Column() {
              // 分区标题
              Row() {
                Text(section.title)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#333333')
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16, bottom: 10 })

              // 横向滑动列表
              Scroll() {
                Row({ space: 10 }) {
                  ForEach(section.content, (album: JmAlbumInfo) => {
                    this.HomeAlbumCard(album)
                  }, (album: JmAlbumInfo, index?: number) => {
                    return `${typeof album.id === 'number' ? album.id : album.id}`
                  })
                }
                .padding({ left: 16, right: 16 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
            }
          }, (section: JmPromoteSection) => section.title)
        }
      }
      .width('100%')
      .padding({ top: this.topSafeHeight + 52 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor('#F5F5F5')
  }

  @Builder
  HomeAlbumCard(album: JmAlbumInfo) {
    Column() {
      Image(this.apiService.buildCoverUrl(album.id))
        .width(this.isTablet ? 150 : 120)
        .height(this.isTablet ? 200 : 160)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
        .backgroundColor('#F0F0F0')

      Text(album.name)
        .fontSize(12)
        .fontColor('#333333')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(16)
        .width(this.isTablet ? 150 : 120)
        .margin({ top: 6 })
    }
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.onAlbumClick(album))
  }
}

// ═══════════════════════════════════════════
// 个人中心（占位）
// ═══════════════════════════════════════════
@Component
struct ProfilePage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;

  onLogin(): void {
    router.pushUrl({ url: 'pages/LoginPage' });
  }

  onFavorites(): void {
    router.pushUrl({ url: 'pages/FavoritePage' });
  }

  build() {
    Scroll() {
      Column() {
        // ── 登录入口 ──
        Row() {
          Image($r('sys.symbol.person'))
            .width(48)
            .height(48)
            .fillColor('#CCCCCC')

          Column() {
            Text('未登录')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
            Text('点击登录以同步收藏')
              .fontSize(13)
              .fontColor('#999999')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 14 })
          .layoutWeight(1)

          Image($r('sys.symbol.chevron_right'))
            .width(20)
            .height(20)
            .fillColor('#CCCCCC')
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 24, bottom: 20 })
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .margin({ top: 16 })
        .onClick(() => this.onLogin())

        // ── 功能列表 ──
        Column() {
          Row() {
            Image($r('sys.symbol.heart'))
              .width(24)
              .height(24)
              .fillColor('#FF5A5F')

            Text('我的收藏')
              .fontSize(16)
              .fontColor('#333333')
              .margin({ left: 12 })
              .layoutWeight(1)

            Image($r('sys.symbol.chevron_right'))
              .width(18)
              .height(18)
              .fillColor('#CCCCCC')
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 16, bottom: 16 })
          .onClick(() => this.onFavorites())
        }
        .width('100%')
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor('#F5F5F5')
  }
}

// ═══════════════════════════════════════════
// 分类页（原 Index 内容）
// ═══════════════════════════════════════════
@Component
struct CategoryPage {
  @State albums: AlbumViewModel[] = [];
  @State isLoading: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State currentCategory: string = CATEGORY_ALL;
  @State currentOrder: string = ORDER_BY_LATEST;
  @State searchKeyword: string = '';
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = new ApiService();
  private cache: CacheManager | null = null;
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  // 分类标签数据
  private categories: string[] = [
    CATEGORY_ALL,
    CATEGORY_DOUJIN,
    CATEGORY_SINGLE,
    CATEGORY_SHORT,
    CATEGORY_HANMAN,
    CATEGORY_MEIMAN,
    CATEGORY_ANOTHER,
    CATEGORY_DOUJIN_COSPLAY,
    CATEGORY_3D,
    CATEGORY_ENGLISH_SITE,
  ];

  // 排序选项
  private orders: OrderItem[] = [
    { key: ORDER_BY_LATEST, label: ORDER_NAME_MAP[ORDER_BY_LATEST] ?? '最新' } as OrderItem,
    { key: ORDER_BY_LIKE, label: ORDER_NAME_MAP[ORDER_BY_LIKE] ?? '最多喜欢' } as OrderItem,
    { key: ORDER_MONTH_RANKING, label: ORDER_NAME_MAP[ORDER_MONTH_RANKING] ?? '月排行' } as OrderItem,
    { key: ORDER_WEEK_RANKING, label: ORDER_NAME_MAP[ORDER_WEEK_RANKING] ?? '周排行' } as OrderItem,
    { key: ORDER_DAY_RANKING, label: ORDER_NAME_MAP[ORDER_DAY_RANKING] ?? '日排行' } as OrderItem,
  ];

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    // 先尝试从缓存加载
    let loaded = await this.loadFromCache();
    if (!loaded) {
      await this.loadAlbums();
    }
  }

  /** 从本地缓存加载已有数据 */
  async loadFromCache(): Promise<boolean> {
    if (!this.cache) return false;
    let cachedPages = this.cache.getCategoryPages(this.currentCategory, this.currentOrder);
    if (cachedPages.length === 0) return false;

    let allAlbums: AlbumViewModel[] = [];
    for (let p of cachedPages.sort((a, b) => a - b)) {
      let entry = this.cache.loadCategoryList(this.currentCategory, this.currentOrder, p);
      if (entry) {
        let items = AlbumViewModel.fromJSONArray(JSON.parse(entry.data) as IAlbumViewModelJSON[]);
        allAlbums = allAlbums.concat(items);
      }
    }
    if (allAlbums.length === 0) return false;

    this.albums = allAlbums;
    this.currentPage = cachedPages.length;
    this.hasMore = allAlbums.length >= 20;
    return true;
  }

  /** 保存数据到缓存 */
  saveToCache(page: number, vms: AlbumViewModel[], total: number): void {
    if (!this.cache) return;
    let data = JSON.stringify(vms.map(vm => vm.toJSON()));
    this.cache.saveCategoryList(this.currentCategory, this.currentOrder, page, data, total);
    this.cache.saveLastCategory(this.currentCategory);
    this.cache.saveLastOrder(this.currentOrder);
  }

  async loadAlbums(): Promise<void> {
    if (this.isLoading) return;
    this.isLoading = true;

    try {
      let resp = await this.apiService.getCategoryList(
        this.currentCategory,
        this.currentOrder,
        this.currentPage
      );

      console.info(`[CategoryPage] getCategoryList resp: code=${resp.code}, data type=${typeof resp.data}`);
      if (resp.code === 200 && resp.data) {
        let data = resp.data as SearchResultData;
        console.info(`[CategoryPage] data.total=${data.total}, content length=${data.content?.length}`);
        let list = data.content;
        let vms = list.map(item => {
          let vm = AlbumViewModel.fromApiInfo(item, '');
          vm.coverUrl = this.apiService.buildCoverUrl(vm.id);
          return vm;
        });

        if (this.currentPage === 1) {
          this.albums = vms;
        } else {
          this.albums = this.albums.concat(vms);
        }

        this.hasMore = vms.length >= 20;

        // 保存到本地缓存
        this.saveToCache(this.currentPage, vms, parseInt(data.total) || 0);
      } else {
        console.error(`[CategoryPage] getCategoryList failed: code=${resp.code}, message=${resp.message}`);
      }
    } catch (err) {
      console.error('loadAlbums error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  async onCategoryChange(category: string): Promise<void> {
    if (this.currentCategory === category) return;
    this.currentCategory = category;
    this.currentPage = 1;
    this.hasMore = true;
    this.albums = [];
    let loaded = await this.loadFromCache();
    if (!loaded) {
      await this.loadAlbums();
    }
  }

  async onOrderChange(order: string): Promise<void> {
    if (this.currentOrder === order) return;
    this.currentOrder = order;
    this.currentPage = 1;
    this.hasMore = true;
    this.albums = [];
    let loaded = await this.loadFromCache();
    if (!loaded) {
      await this.loadAlbums();
    }
  }

  loadMore(): void {
    if (!this.hasMore || this.isLoading) return;
    this.currentPage++;
    this.loadAlbums();
  }

  onAlbumClick(album: AlbumViewModel): void {
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: { albumId: album.id, albumName: album.name }
    });
  }

  onSearch(): void {
    router.pushUrl({
      url: 'pages/SearchPage'
    });
  }

  onLogin(): void {
    router.pushUrl({
      url: 'pages/LoginPage'
    });
  }

  onFavorites(): void {
    router.pushUrl({
      url: 'pages/FavoritePage'
    });
  }

  build() {
    Stack() {
      // ── 漫画列表（全屏滚动） ──
      Column() {
        // ── 漫画列表 (瀑布流) ──
        if (this.albums.length === 0 && this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#FF5A5F')
            Text('加载中...')
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.albums.length === 0) {
          Column() {
            Text('暂无数据')
              .fontSize(16)
              .fontColor('#999999')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Grid() {
              ForEach(this.albums, (album: AlbumViewModel, index: number) => {
                GridItem() {
                  this.AlbumCard(album)
                }
                .onClick(() => this.onAlbumClick(album))
              })
            }
            .columnsTemplate(this.isTablet ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
            .columnsGap(10)
            .rowsGap(10)
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .padding({ top: this.topSafeHeight + 160, bottom: 80 })
          .onReachEnd(() => this.loadMore())
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')

      // ── 浮层：排序 + 分类标签（毛玻璃） ──
      Column() {
        // ── 排序选择器 ──
        Row() {
          ForEach(this.orders, (item: OrderItem) => {
            Text(item.label)
              .fontSize(13)
              .fontColor(this.currentOrder === item.key ? '#FF5A5F' : '#666666')
              .fontWeight(this.currentOrder === item.key ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.currentOrder === item.key ? '#FFF0F0' : '#F5F5F5')
              .borderRadius(14)
              .margin({ right: 8 })
              .onClick(() => this.onOrderChange(item.key))
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        // ── 分类标签 (横向滚动) ──
        Scroll() {
          Row() {
            ForEach(this.categories, (cat: string) => {
              Text(CATEGORY_NAME_MAP[cat] ?? cat)
                .fontSize(14)
                .fontColor(this.currentCategory === cat ? '#FFFFFF' : '#666666')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor(this.currentCategory === cat ? '#FF5A5F' : '#F5F5F5')
                .borderRadius(16)
                .margin({ right: 8 })
                .onClick(() => this.onCategoryChange(cat))
            })
          }
          .padding({ left: 16, right: 16, top: 0, bottom: 8 })
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(52)
      }
      .position({ x: 0, y: this.topSafeHeight + 48 })
      .width('100%')
      .padding({ top: 4 })
      .backgroundColor('rgba(255, 255, 255, 0.85)')
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  AlbumCard(album: AlbumViewModel) {
    Column() {
      // 封面图
      Image(album.coverUrl)
        .width('100%')
        .aspectRatio(0.72)
        .objectFit(ImageFit.Cover)
        .borderRadius({ topLeft: 8, topRight: 8 })
        .backgroundColor('#F0F0F0')

      // 信息区
      Column() {
        Text(album.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .constraintSize({ minHeight: 36 })
          .align(Alignment.Top)

        Row() {
          Text(album.author)
            .fontSize(11)
            .fontColor('#999999')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (album.totalViews && album.totalViews !== '0') {
            Text(`${album.totalViews} 次`)
              .fontSize(10)
              .fontColor('#CCCCCC')
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .shadow({
      radius: 4,
      color: '#10000000',
      offsetX: 0,
      offsetY: 2
    })
  }
}

// ═══════════════════════════════════════════
// 讨论区
// ═══════════════════════════════════════════
@Component
struct ForumPage {
  @State comments: CommentInfo[] = [];
  @State isLoading: boolean = true;
  @State isLoadingMore: boolean = false;
  @State currentPage: number = 1;
  @State totalComments: number = 0;
  @State hasMore: boolean = true;
  @State currentMode: string = COMMENT_MODE_ALL;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = new ApiService();

  private modes: ForumModeItem[] = [
    { key: COMMENT_MODE_ALL, label: COMMENT_MODE_NAME_MAP[COMMENT_MODE_ALL] } as ForumModeItem,
    { key: COMMENT_MODE_MANHUA, label: COMMENT_MODE_NAME_MAP[COMMENT_MODE_MANHUA] } as ForumModeItem,
    { key: COMMENT_MODE_CHAT, label: COMMENT_MODE_NAME_MAP[COMMENT_MODE_CHAT] } as ForumModeItem,
  ];

  async aboutToAppear(): Promise<void> {
    await this.loadComments();
  }

  async loadComments(): Promise<void> {
    this.isLoading = true;
    try {
      let data: CommentPageData = await this.apiService.getComments(this.currentMode, '', this.currentPage);
      this.totalComments = data.total;
      this.comments = (data.list || []).map((raw) => parseCommentRaw(raw));
      this.hasMore = this.comments.length < this.totalComments;
    } catch (err) {
      console.error('[ForumPage] loadComments error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  async loadMoreComments(): Promise<void> {
    if (!this.hasMore || this.isLoadingMore) return;
    this.isLoadingMore = true;
    this.currentPage++;
    try {
      let data: CommentPageData = await this.apiService.getComments(this.currentMode, '', this.currentPage);
      let newComments = (data.list || []).map((raw) => parseCommentRaw(raw));
      this.comments = this.comments.concat(newComments);
      this.hasMore = this.comments.length < this.totalComments;
    } catch (err) {
      console.error('[ForumPage] loadMoreComments error:', JSON.stringify(err));
      this.currentPage--;
    } finally {
      this.isLoadingMore = false;
    }
  }

  async onModeChange(mode: string): Promise<void> {
    if (this.currentMode === mode) return;
    this.currentMode = mode;
    this.currentPage = 1;
    this.comments = [];
    this.hasMore = true;
    await this.loadComments();
  }

  build() {
    Column() {
      // ── 模式筛选栏 ──
      Row() {
        ForEach(this.modes, (item: ForumModeItem) => {
          Text(item.label)
            .fontSize(13)
            .fontColor(this.currentMode === item.key ? '#FF5A5F' : '#666666')
            .fontWeight(this.currentMode === item.key ? FontWeight.Bold : FontWeight.Normal)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor(this.currentMode === item.key ? '#FFF0F0' : '#F5F5F5')
            .borderRadius(14)
            .margin({ right: 8 })
            .onClick(() => this.onModeChange(item.key))
        })

        Blank()

        Text(`${this.totalComments} 条`)
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#FFFFFF')

      // ── 评论列表 ──
      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color('#FF5A5F')
          Text('加载中...')
            .fontSize(14)
            .fontColor('#999999')
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.comments.length === 0) {
        Column() {
          Text('暂无评论')
            .fontSize(16)
            .fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.comments, (comment: CommentInfo, index: number) => {
              CommentItemComponent({
                comment: comment,
                index: index + 1,
                onSendReply: this.handleSendReply,
              })
                .margin({ top: 8, left: 12, right: 12 })
            }, (comment: CommentInfo) => comment.id)

            if (this.isLoadingMore) {
              Row() {
                LoadingProgress()
                  .width(24)
                  .height(24)
                  .color('#FF5A5F')
                Text('加载更多...')
                  .fontSize(13)
                  .fontColor('#999999')
                  .margin({ left: 8 })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 16, bottom: 16 })
            } else if (this.hasMore) {
              Text('上拉加载更多')
                .fontSize(13)
                .fontColor('#CCCCCC')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 16 })
            } else {
              Text('没有更多了')
                .fontSize(13)
                .fontColor('#CCCCCC')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 16 })
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          if (!this.isLoadingMore && this.hasMore) {
            this.loadMoreComments();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topSafeHeight + 52, bottom: 80 })
    .backgroundColor('#F5F5F5')
  }

  async handleSendReply(commentId: string, albumId: string, text: string): Promise<void> {
    if (!this.apiService.isLoggedIn()) {
      try {
        await promptAction.showToast({ message: '请先登录后再回复', duration: 2000 });
      } catch (e) {
        console.error('[ForumPage] showToast error:', JSON.stringify(e));
      }
      return;
    }
    try {
      let msg = await this.apiService.sendComment(albumId, text, commentId);
      console.info('[ForumPage] 回复成功:', msg);
    } catch (err) {
      console.error('[ForumPage] 回复失败:', JSON.stringify(err));
    }
  }
}

// ═══════════════════════════════════════════
// 主入口 — HdsTabs 悬浮页签
// ═══════════════════════════════════════════
@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State showRouteMenu: boolean = false;
  @State apiDomains: string[] = [];
  @State imageDomains: string[] = [];
  @State selectedApiIndex: number = -1;
  @State selectedImageIndex: number = -1;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  private controller: HdsTabsController = new HdsTabsController();
  private apiService: ApiService = new ApiService();

  onSearch(): void {
    router.pushUrl({ url: 'pages/SearchPage' });
  }

  onToggleRoute(): void {
    let dm = this.apiService.getDomainManager();
    this.apiDomains = dm.getApiDomains();
    this.imageDomains = dm.getImageDomains();
    this.selectedApiIndex = dm.getSelectedApiIndex();
    this.selectedImageIndex = dm.getSelectedImageIndex();
    this.showRouteMenu = true;
  }

  onApiRouteSelect(index: number): void {
    this.apiService.getDomainManager().setApiIndex(index);
    this.selectedApiIndex = index;
  }

  onImageRouteSelect(index: number): void {
    this.apiService.getDomainManager().setImageIndex(index);
    this.selectedImageIndex = index;
  }

  build() {
    Stack() {
      // ── 全屏 HdsTabs（内容可延伸到顶部栏背后）──
      HdsTabs({ controller: this.controller, index: this.currentIndex }) {
        // ── 首页 ──
        TabContent() {
          HomePage()
        }
        .tabBar(new BottomTabBarStyle($r('sys.symbol.house'), '首页'))

        // ── 分类 ──
        TabContent() {
          CategoryPage()
        }
        .tabBar(new BottomTabBarStyle($r('sys.symbol.square_grid_2x2'), '分类'))

        // ── 讨论区 ──
        TabContent() {
          ForumPage()
        }
        .tabBar(new BottomTabBarStyle($r('sys.symbol.message'), '讨论区'))

        // ── 个人中心 ──
        TabContent() {
          ProfilePage()
        }
        .tabBar(new BottomTabBarStyle($r('sys.symbol.person'), '个人中心'))
      }
      .barPosition(BarPosition.End)
      .barOverlap(true)
      .barFloatingStyle({
        barSideMargin: 16,
        barBottomMargin: 16,
        barOpacity: 0.9,
      })
      .animationDuration(300)
      .scrollable(true)
      .width('100%')
      .height('100%')
      .onChange((index: number) => {
        this.currentIndex = index;
      })

      // ── 沉浸式顶部栏（浮层 + 毛玻璃） ──
      Row() {
        Text('JMComic')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
          .layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          Text('线路')
            .fontSize(15)
            .fontColor('#666666')
        }
        .backgroundColor('#F5F5F5')
        .borderRadius(18)
        .width(64)
        .height(36)
        .margin({ right: 8 })
        .onClick(() => this.onToggleRoute())

        Button({ type: ButtonType.Normal }) {
          Text('搜索')
            .fontSize(15)
            .fontColor('#666666')
        }
        .backgroundColor('#F5F5F5')
        .borderRadius(18)
        .width(80)
        .height(36)
        .onClick(() => this.onSearch())
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor('rgba(245, 245, 245, 0.85)')
      .backdropBlur(20)
      .zIndex(10)

      // ── 线路菜单弹窗 ──
      if (this.showRouteMenu) {
        Stack() {
          buildMenuOverlay(() => { this.showRouteMenu = false; })
          buildRouteMenu(
            [
              {
                title: 'API',
                routes: this.apiDomains,
                selectedIndex: this.selectedApiIndex,
                onSelect: (index: number) => { this.onApiRouteSelect(index); }
              } as RouteColumn,
              {
                title: '图片',
                routes: this.imageDomains,
                selectedIndex: this.selectedImageIndex,
                onSelect: (index: number) => { this.onImageRouteSelect(index); }
              } as RouteColumn,
            ] as RouteColumn[],
            { x: '100%', y: this.topSafeHeight + 48 },
            () => { this.showRouteMenu = false; }
          )
        }
        .width('100%')
        .height('100%')
        .zIndex(100)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
