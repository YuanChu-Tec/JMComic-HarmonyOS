import { router, display, promptAction } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { ApiService } from '../network/ApiService';
import { AlbumViewModel, JmAlbumInfo, JmPromoteSection, SearchResultData, IAlbumViewModelJSON,
  CommentInfo, CommentPageData, parseCommentRaw,
  COMMENT_MODE_ALL, COMMENT_MODE_MANHUA, COMMENT_MODE_CHAT, COMMENT_MODE_NAME_MAP,
  UserSession,
  FavoriteAlbumItem, FavoriteFolderItem, FavoritePageData, FavoriteFolderType,
} from '../models/Album';
import { CacheManager } from '../common/CacheManager';
import {
  CATEGORY_ALL, CATEGORY_DOUJIN, CATEGORY_SINGLE, CATEGORY_SHORT,
  CATEGORY_ANOTHER, CATEGORY_HANMAN, CATEGORY_MEIMAN,
  CATEGORY_DOUJIN_COSPLAY, CATEGORY_3D, CATEGORY_ENGLISH_SITE,
  CATEGORY_NAME_MAP, ORDER_BY_LATEST, ORDER_MONTH_RANKING,
  ORDER_WEEK_RANKING, ORDER_DAY_RANKING, ORDER_BY_LIKE,
  ORDER_NAME_MAP, PAGE_SIZE_FAVORITE,
} from '../common/Constants';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { MenuItem, buildMenuPopup, RouteColumn, buildRouteMenu, buildMenuOverlay } from '../common/MenuPopup';
import { CommentItemComponent } from '../common/CommentItem';
import { DeviceUtils } from 'common';

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
  @State latestAlbums: JmAlbumInfo[] = [];
  @State isLoading: boolean = true;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  async aboutToAppear(): Promise<void> {
    try {
      let results = await Promise.all([
        this.apiService.getPromote(),
        this.apiService.getLatest()
      ]);
      let promoteResp = results[0];
      let latestResp = results[1];
      if (promoteResp.code === 200 && promoteResp.data) {
        this.sections = promoteResp.data as JmPromoteSection[];
      }
      if (latestResp.code === 200 && latestResp.data) {
        this.latestAlbums = latestResp.data as JmAlbumInfo[];
      }
    } catch (err) {
      console.error('[HomePage] load error:', JSON.stringify(err));
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
        } else if (this.sections.length === 0 && this.latestAlbums.length === 0) {
          Column() {
            Text('暂无数据')
              .fontSize(16)
              .fontColor('#999999')
          }
          .width('100%')
          .height(300)
          .justifyContent(FlexAlign.Center)
        } else {
          // ── 最新上传分区（始终最前） ──
          if (this.latestAlbums.length > 0) {
            Column() {
              Row() {
                Text('最新上传')
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#333333')
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16, bottom: 10 })

              Scroll() {
                Row({ space: 10 }) {
                  ForEach(this.latestAlbums, (album: JmAlbumInfo) => {
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
          }

          // ── 推广分区 ──
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
// 个人中心（显示登录状态和用户信息 + 收藏漫画流）
// ═══════════════════════════════════════════
@Component
struct ProfilePage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  @StorageProp('isLoggedIn') @Watch('onLoginStateChanged') isLoggedIn: boolean = false;
  @State favAlbums: AlbumViewModel[] = [];
  @State favFolders: FavoriteFolderItem[] = [];
  @State favCurrentFolderId: string = '0';
  @State favIsLoading: boolean = false;
  @State favCurrentPage: number = 1;
  @State favHasMore: boolean = true;
  @State favTotal: number = 0;
  @State favNeedLoad: boolean = false;
  private apiService: ApiService = ApiService.getInstance();
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  aboutToAppear(): void {
    AppStorage.setOrCreate('isLoggedIn', this.apiService.isLoggedIn());
    // 直接检查登录状态，避免onAppear时机问题
    if (this.apiService.isLoggedIn()) {
      this.favNeedLoad = true;
      this.loadFavorites();
    }
  }

  /** 当isLoggedIn变化时（如自动登录完成），触发收藏加载 */
  onLoginStateChanged(): void {
    if (this.isLoggedIn && !this.favNeedLoad) {
      this.favNeedLoad = true;
      this.loadFavorites();
    }
  }

  async onLogin(): Promise<void> {
    if (!this.isLoggedIn) {
      router.pushUrl({ url: 'pages/LoginPage' });
    }
  }

  onLogout(): void {
    this.apiService.logout();
    this.isLoggedIn = false;
    this.favAlbums = [];
    this.favTotal = 0;
    this.favNeedLoad = false;
  }

  async loadFavorites(): Promise<void> {
    if (this.favIsLoading) return;
    this.favIsLoading = true;
    try {
      let resp = await this.apiService.getFavorites(this.favCurrentPage, this.favCurrentFolderId);
      if (resp.code === 200 && resp.data) {
        let pageData = resp.data;
        this.favTotal = pageData.total;
        this.favFolders = pageData.folder_list || [];
        let vms = pageData.list.map((item: FavoriteAlbumItem) => {
          let vm = new AlbumViewModel();
          vm.id = parseInt(item.id);
          vm.name = item.name;
          vm.author = Array.isArray(item.author) ? item.author.join(', ') : item.author;
          vm.description = item.description;
          vm.category = item.category?.title || '';
          vm.coverUrl = this.apiService.buildCoverUrl(vm.id);
          return vm;
        });
        if (this.favCurrentPage === 1) {
          this.favAlbums = vms;
        } else {
          this.favAlbums = this.favAlbums.concat(vms);
        }
        this.favHasMore = this.favAlbums.length < this.favTotal;
      }
    } catch (err) {
      console.error('[ProfilePage] loadFavorites error:', JSON.stringify(err));
    } finally {
      this.favIsLoading = false;
    }
  }

  onFolderChange(folderId: string): void {
    if (this.favCurrentFolderId === folderId) return;
    this.favCurrentFolderId = folderId;
    this.favCurrentPage = 1;
    this.favHasMore = true;
    this.favAlbums = [];
    this.loadFavorites();
  }

  buildAvatarUrl(): string {
    let photo = this.apiService.getUserSession().photo;
    if (!photo) return '';
    let domain = this.apiService.getImageDomain();
    return `https://${domain}/media/users/${photo}`;
  }

  onAlbumClick(album: AlbumViewModel): void {
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: { albumId: album.id, albumName: album.name }
    });
  }

  build() {
    Scroll() {
      Column() {
        if (this.isLoggedIn) {
          // ── 已登录状态 ──

          // 用户头像和信息
          Column() {
            if (this.buildAvatarUrl()) {
              Image(this.buildAvatarUrl())
                .width(80)
                .height(80)
                .borderRadius(40)
                .objectFit(ImageFit.Cover)
                .backgroundColor('#F0F0F0')
                .margin({ top: 24, bottom: 12 })
            } else {
              Image($r('app.media.ic_default_avatar'))
                .width(80)
                .height(80)
                .borderRadius(40)
                .objectFit(ImageFit.Cover)
                .backgroundColor('#F0F0F0')
                .margin({ top: 24, bottom: 12 })
            }

            Text(this.apiService.getUserSession().username)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#333333')

            Text(`Lv.${this.apiService.getUserSession().level} · ${this.apiService.getUserSession().levelName}`)
              .fontSize(13)
              .fontColor('#999999')
              .margin({ top: 4 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 16, bottom: 16 })
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .margin({ top: 16 })

          // 统计卡片
          Row() {
            this.StatItem('金币', this.apiService.getUserSession().coin.toString())
            this.StatItem('收藏', `${this.favTotal > 0 ? this.favTotal : this.apiService.getUserSession().albumFavorites}/${this.apiService.getUserSession().albumFavoritesMax}`)
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 20, bottom: 20 })
          .justifyContent(FlexAlign.SpaceEvenly)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .margin({ top: 12 })

          // 退出按钮
          Button({ type: ButtonType.Normal }) {
            Text('退出登录')
              .fontSize(15)
              .fontColor('#FF5A5F')
          }
          .backgroundColor('#FFF0F0')
          .borderRadius(22)
          .width(200)
          .height(44)
          .margin({ top: 24 })
          .onClick(() => this.onLogout())

          // ── 我的收藏（漫画流） ──
          Column() {
            // 收藏夹标签
            if (this.favFolders.length > 0) {
              Scroll() {
                Row() {
                  Text('全部')
                    .fontSize(13)
                    .fontColor(this.favCurrentFolderId === '0' ? '#FFFFFF' : '#666666')
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .backgroundColor(this.favCurrentFolderId === '0' ? '#FF5A5F' : '#F5F5F5')
                    .borderRadius(14)
                    .margin({ right: 8 })
                    .onClick(() => this.onFolderChange('0'))

                  ForEach(this.favFolders, (folder: FavoriteFolderItem) => {
                    Text(folder.name)
                      .fontSize(13)
                      .fontColor(this.favCurrentFolderId === folder.FID ? '#FFFFFF' : '#666666')
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .backgroundColor(this.favCurrentFolderId === folder.FID ? '#FF5A5F' : '#F5F5F5')
                      .borderRadius(14)
                      .margin({ right: 8 })
                      .onClick(() => this.onFolderChange(folder.FID))
                  })
                }
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              }
              .width('100%')
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
            }

            // 漫画流
            if (this.favAlbums.length === 0 && this.favIsLoading) {
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
            } else if (this.favAlbums.length === 0) {
              Column() {
                Text('暂无收藏')
                  .fontSize(16)
                  .fontColor('#999999')
              }
              .width('100%')
              .height(200)
              .justifyContent(FlexAlign.Center)
            } else {
              Grid() {
                ForEach(this.favAlbums, (album: AlbumViewModel) => {
                  GridItem() {
                    this.FavAlbumCard(album)
                  }
                  .onClick(() => this.onAlbumClick(album))
                }, (album: AlbumViewModel) => `${album.id}`)
              }
              .columnsTemplate(this.isTablet ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
              .columnsGap(10)
              .rowsGap(10)
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            }

            // 加载更多
            if (this.favHasMore && !this.favIsLoading) {
              Text('加载更多...')
                .fontSize(13)
                .fontColor('#CCCCCC')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 16 })
                .onClick(() => {
                  this.favCurrentPage++;
                  this.loadFavorites();
                })
            }

            if (this.favIsLoading && this.favAlbums.length > 0) {
              Row() {
                LoadingProgress()
                  .width(24)
                  .height(24)
                  .color('#FF5A5F')
                Text('加载中...')
                  .fontSize(13)
                  .fontColor('#999999')
                  .margin({ left: 8 })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 16, bottom: 16 })
            }

            if (!this.favHasMore && this.favAlbums.length > 0) {
              Text('没有更多了')
                .fontSize(12)
                .fontColor('#CCCCCC')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 20 })
            }
          }
          .width('100%')
          .margin({ top: 12 })
          .onAppear(() => {
            if (this.isLoggedIn) {
              this.favCurrentPage = 1;
              this.favHasMore = true;
              this.favAlbums = [];
              this.favNeedLoad = true;
              this.loadFavorites();
            }
          })
        } else {
          // ── 未登录状态 ──

          Row() {
            SymbolGlyph($r('sys.symbol.person'))
              .fontSize(48)
              .fontColor(['#CCCCCC'])

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

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(20)
              .fontColor(['#CCCCCC'])
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 24, bottom: 20 })
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .margin({ top: 16 })
          .onClick(() => this.onLogin())
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 40, bottom: 80 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor('#F5F5F5')
  }

  @Builder
  StatItem(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#333333')
      Text(label)
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  FavAlbumCard(album: AlbumViewModel) {
    Column() {
      Image(album.coverUrl)
        .width('100%')
        .aspectRatio(0.72)
        .objectFit(ImageFit.Cover)
        .borderRadius({ topLeft: 8, topRight: 8 })
        .backgroundColor('#F0F0F0')
        .constraintSize({ maxWidth: this.isTablet ? 200 : 180 })

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
// 分类页
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
  private apiService: ApiService = ApiService.getInstance();
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

  buildAvatarUrl(): string {
    let photo = this.apiService.getUserSession().photo;
    if (!photo) return '';
    let domain = this.apiService.getImageDomain();
    return `https://${domain}/media/users/${photo}`;
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

  onMoreCategory(): void {
    router.pushUrl({
      url: 'pages/SearchPage'
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

            // 查看更多
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor(['#666666'])
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('#F5F5F5')
              .borderRadius(16)
              .onClick(() => this.onMoreCategory())
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
  private apiService: ApiService = ApiService.getInstance();

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
  private apiService: ApiService = ApiService.getInstance();

  async aboutToAppear(): Promise<void> {
    // 自动登录：从 preferences 读取已保存的凭据
    try {
      let prefs = await preferences.getPreferences(getContext(), 'JMComicUser');
      let savedUser = prefs.getSync('username', '') as string;
      let savedPass = prefs.getSync('password', '') as string;
      if (savedUser && savedPass) {
        console.info('[Index] 尝试自动登录, username=' + savedUser);
        await this.apiService.login(savedUser, savedPass);
        console.info('[Index] 自动登录成功');
      }
    } catch (err) {
      console.warn('[Index] 自动登录失败:', JSON.stringify(err));
    }
  }

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

  @Builder TabBarBuilder(icon: Resource, label: string, index: number) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.currentIndex === index ? '#007AFF' : '#8E8E93'])
      Text(label)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? '#007AFF' : '#8E8E93')
    }
    .padding({ top: 8, bottom: 4 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack() {
      // ── 全屏 HdsTabs（内容可延伸到顶部栏背后）──
      if (canIUse("SystemCapability.UIDesign.HDSComponent.Core")) {
        HdsTabs({ controller: this.controller, index: this.currentIndex }) {
          // ── 首页 ──
          TabContent() {
            HomePage()
          }
          .tabBar(this.TabBarBuilder($r('sys.symbol.house'), '首页', 0))

          // ── 分类 ──
          TabContent() {
            CategoryPage()
          }
          .tabBar(this.TabBarBuilder($r('sys.symbol.square_grid_2x2'), '分类', 1))

          // ── 讨论区 ──
          TabContent() {
            ForumPage()
          }
          .tabBar(this.TabBarBuilder($r('sys.symbol.message'), '讨论区', 2))

          // ── 个人中心 ──
          TabContent() {
            ProfilePage()
          }
          .tabBar(this.TabBarBuilder($r('sys.symbol.person'), '个人中心', 3))
        }
        .id('HdsTabsBottom')
        .barPosition(BarPosition.End)
        .barOverlap(true)
        .barFloatingStyle({
          barBottomMargin: 16,
          systemMaterialEffect: DeviceUtils.isEmulator() ? undefined : {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
          }
        })
        .animationDuration(300)
        .scrollable(true)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.currentIndex = index;
        })
      } else {
        // Fallback for unsupported SystemCapability
      }

      // ── 沉浸式顶部栏（浮层 + 毛玻璃） ──
      Row() {
        Text('JMComic')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')

        Button({ type: ButtonType.Normal }) {
          Text('防失联')
            .fontSize(13)
            .fontColor('#FF5A5F')
        }
        .backgroundColor('#FFF0F0')
        .borderRadius(14)
        .height(32)
        .padding({ left: 10, right: 10 })
        .margin({ left: 8 })
        .onClick(() => router.pushUrl({ url: 'pages/AboutPage' }))

        Blank()

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
