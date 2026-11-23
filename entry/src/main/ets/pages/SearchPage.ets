import { display } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import { AlbumViewModel } from '../models/Album';
import { AlbumDao } from '../storage/AlbumDao';
import { CacheManager } from '../common/CacheManager';
import { navPush, navPop } from '../common/NavHelper';
import { AlbumDetailParams } from '../common/RouteParams';

@Component
struct SearchPage {
  @State keyword: string = '';
  @State albums: AlbumViewModel[] = [];
  @State isLoading: boolean = false;
  @State hasSearched: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = false;
  @State searchHistory: string[] = [];
  @State searchFailed: boolean = false;
  /** 下拉刷新指示器：只有搜索态下才会亮起 */
  @State isRefreshing: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private cache: CacheManager | null = null;
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;
  /** 本地结果最近一次落库时间，用来判断是否过期 */
  private localUpdatedAt: number = 0;
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  // NavDestination 标准入口：参数与数据加载移入 onReady（原 router.getParams 时代在 aboutToAppear）
  private async onPageReady(ctx: NavDestinationContext): Promise<void> {
    this.cache = await CacheManager.getInstance();
    this.searchHistory = this.cache.getSearchHistory();
    let params = ctx.pathInfo.param as Record<string, string> | null;
    if (params && params.keyword) {
      this.keyword = params.keyword;
      this.doSearch();
    }
  }

  async doSearch(isNewSearch: boolean = true): Promise<void> {
    let kw = this.keyword.trim();
    if (kw.length === 0) return;

    // 纯数字视为 Album ID，直接跳转详情页
    if (/^\d+$/.test(kw)) {
      this.isLoading = true;
      try {
        let resp = await this.apiService.getAlbumDetail(parseInt(kw));
        if (resp.code === 200 && resp.data) {
          if (this.cache) {
            this.cache.addSearchHistory(kw);
            this.searchHistory = this.cache.getSearchHistory();
          }
          navPush('AlbumDetailPage', { albumId: parseInt(kw), albumName: resp.data.name || '' } as AlbumDetailParams);
        } else {
          console.error(`[SearchPage] album id=${kw} not found: ${resp.message}`);
          this.showToast('未找到该漫画');
        }
      } catch (err) {
        console.error(`[SearchPage] album id=${kw} error: ${JSON.stringify(err)}`);
        this.searchFailed = true;
        this.showToast('网络异常，请重试');
      } finally {
        this.isLoading = false;
      }
      return;
    }

    if (isNewSearch) {
      this.currentPage = 1;
      this.hasSearched = true;
      this.albums = [];
    }

    if (this.isLoading) return;

    // 保存搜索历史
    if (isNewSearch && this.cache) {
      this.cache.addSearchHistory(kw);
      this.searchHistory = this.cache.getSearchHistory();
    }

    // 一进函数就置加载态：读库这几毫秒也别让用户看到空列表
    this.isLoading = true;
    this.searchFailed = false;

    // 本地优先：新搜索回放全部已落库页，翻页只看这一页在不在
    let prefix = `search:${kw}:p`;
    if (isNewSearch) {
      let hasLocal = await this.renderFromStore(prefix);
      if (hasLocal && !this.isStale()) {
        let pages = await AlbumDao.feedPageNumbers(prefix);
        this.currentPage = pages.length > 0 ? pages[pages.length - 1] : 1;
        this.isLoading = false;
        return;
      }
      if (hasLocal) {
        // 过期：整个关键词的本地结果作废，重新从第一页拉
        await AlbumDao.clearFeedPrefix(prefix);
        this.albums = [];
        this.currentPage = 1;
      }
    } else {
      let cached = await AlbumDao.loadFeed(`${prefix}${this.currentPage}`);
      if (cached.sections.length > 0 && cached.sections[0].albums.length > 0) {
        await this.renderFromStore(prefix);
        this.hasMore = cached.sections[0].albums.length >= 20;
        this.isLoading = false;
        return;
      }
    }

    // 本地缺失才走网络

    try {
      let resp = await this.apiService.search(kw, this.currentPage);

      if (resp.code === 200 && resp.data) {
        // 先落库，再从库读回来渲染
        await AlbumDao.saveFeed(`${prefix}${this.currentPage}`, resp.data.content, parseInt(resp.data.total) || 0);
        await this.renderFromStore(prefix);
        this.hasMore = resp.data.content.length >= 20;
      }
    } catch (err) {
      console.error('search error:', JSON.stringify(err));
      this.searchFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  /** 从库里读出这个关键词的所有分页并渲染 */
  private async renderFromStore(prefix: string): Promise<boolean> {
    let snapshots = await AlbumDao.loadFeedPages(prefix);
    let albums: AlbumViewModel[] = [];
    this.localUpdatedAt = 0;
    for (let snapshot of snapshots) {
      this.localUpdatedAt = Math.max(this.localUpdatedAt, snapshot.updatedAt);
      if (snapshot.sections.length === 0) continue;
      for (let album of snapshot.sections[0].albums) {
        albums.push(AlbumViewModel.fromAlbum(album,
          this.apiService.coverSource(album.id, '_3x4', album.imageName)));
      }
    }
    this.albums = albums;
    return albums.length > 0;
  }

  /** 本地结果是否过期（TTL 由设置页的间隔 + 「搜索列表」开关共同控制） */
  private isStale(): boolean {
    return Date.now() - this.localUpdatedAt > CacheManager.feedTtlMsOf(CacheManager.REFRESH_SEARCH);
  }

  /**
   * 下拉刷新：仅搜索态可用，用当前关键词从第一页重搜。
   * 未搜索（只有历史/语法提示）或纯数字（那是跳详情）都没有可刷新的列表。
   * 与首页同款：不清 this.albums，旧内容留在屏上，落库后由 renderFromStore 整体替换。
   */
  private async pullRefresh(): Promise<void> {
    let kw = this.keyword.trim();
    if (this.isPulling || !this.hasSearched || kw.length === 0 || /^\d+$/.test(kw)) {
      this.isRefreshing = false;
      return;
    }
    this.isPulling = true;
    let prefix = `search:${kw}:p`;
    try {
      let resp = await this.apiService.search(kw, 1);
      if (resp.code === 200 && resp.data) {
        // 旧分页不再对应这份结果，整批作废后只写新的第一页
        await AlbumDao.clearFeedPrefix(prefix);
        await AlbumDao.saveFeedKeepList(`${prefix}1`, resp.data.content, parseInt(resp.data.total) || 0);
        this.currentPage = 1;
        this.hasMore = resp.data.content.length >= 20;
        await this.renderFromStore(prefix);
      } else {
        this.showToast('刷新失败，已保留本地内容');
      }
    } catch (err) {
      console.error('[SearchPage] pull refresh error:', JSON.stringify(err));
      this.showToast('刷新失败，已保留本地内容');
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
    }
  }

  private showToast(message: string): void {
    // Toast 统一走 UIContext 形态（开发规范 §5.5，禁模块级 promptAction 直呼）
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  loadMore(): void {
    if (!this.hasMore || this.isLoading) return;
    this.currentPage++;
    this.doSearch(false);
  }

  onAlbumClick(album: AlbumViewModel): void {
    navPush('AlbumDetailPage', { albumId: album.id, albumName: album.name } as AlbumDetailParams);
  }

  onBack(): void {
    if (this.hasSearched) {
      this.hasSearched = false;
      this.albums = [];
      this.currentPage = 1;
      this.hasMore = false;
    } else {
      navPop();
    }
  }

  // 系统返回拦截（原 @Entry onBackPress → NavDestination.onBackPressed）
  onBackPress(): boolean {
    if (this.hasSearched) {
      this.onBack();
      return true;
    }
    return false;
  }

  build() {
    NavDestination() {
    Stack() {
      // ── 内容区域（延伸到搜索栏背后） ──
      Column() {
        // ── 结果区域 ──
        if (this.isLoading && this.albums.length === 0) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.brand'))
            Text('搜索中...')
              .fontSize(14)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.searchFailed && this.hasSearched && this.albums.length === 0) {
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
              .onClick(() => this.doSearch(true))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.hasSearched && this.albums.length === 0) {
          Column() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(48)
              .fontColor([$r('app.color.text_disabled')])
            Text('未找到相关漫画')
              .fontSize(16)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (!this.hasSearched) {
          Column() {
            // 搜索语法提示：+标签 包含，-标签 排除，空格分隔多个条件
            Row() {
              Text('+标签 包含 · -标签 排除 · 空格分隔')
                .fontSize(12)
                .fontColor('#999999')
                .layoutWeight(1)

              Text('示例【+全彩 +人妻】')
                .fontSize(12)
                .fontColor('#999999')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 2 })

            if (this.searchHistory.length > 0) {
              // 搜索历史
              Column() {
                Row() {
                  Text('搜索历史')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)

                  Text('清空')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
                    .onClick(() => {
                      if (this.cache) {
                        this.cache.clearSearchHistory();
                        this.searchHistory = [];
                      }
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 16, bottom: 8 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.searchHistory, (item: string) => {
                    Text(item)
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                      .backgroundColor($r('app.color.bg_page'))
                      .borderRadius(16)
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        this.keyword = item;
                        this.doSearch();
                      })
                  }, (item: string) => item)
                }
                .padding({ left: 16, right: 16 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            } else {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(48)
                .fontColor([$r('app.color.text_disabled')])
              Text('输入关键词搜索漫画')
                .fontSize(15)
                .fontColor($r('app.color.text_disabled'))
                .margin({ top: 12 })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .padding({ top: this.topSafeHeight + 56, bottom: this.bottomSafeHeight + 16 })
        } else {
          Refresh({ refreshing: $$this.isRefreshing }) {
          Scroll() {
            Column() {
              Grid() {
                ForEach(this.albums, (album: AlbumViewModel) => {
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

              if (this.isLoading) {
                Row() {
                  LoadingProgress()
                    .width(24)
                    .height(24)
                    .color($r('app.color.brand'))
                  Text('加载更多...')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 16, bottom: 16 })
              } else if (this.searchFailed) {
                Row() {
                  Text('加载失败')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                  Text('重新加载')
                    .fontSize(13)
                    .fontColor($r('app.color.brand'))
                    .margin({ left: 12 })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 16, bottom: 16 })
                .onClick(() => this.doSearch(false))
              } else if (!this.hasMore) {
                Text('没有更多了')
                  .fontSize(13)
                  .fontColor($r('app.color.text_disabled'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 16, bottom: 16 })
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .padding({ top: this.topSafeHeight + 56, bottom: this.bottomSafeHeight + 16 })
          .onReachEnd(() => this.loadMore())
          }
          .onRefreshing(() => {
            this.pullRefresh();
          })
          .width('100%')
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_card'))

      // ── 搜索栏（浮层 + 毛玻璃） ──
      Row() {
        // 返回：40×40 标准点击体（裸 SymbolGlyph 字形宽仅约 13vp，不达 24vp 规范）
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .onClick(() => this.onBack())

        Stack({ alignContent: Alignment.End }) {
          TextInput({ placeholder: '输入关键词搜索...', text: this.keyword })
            .width('100%')
            .height(40)
            .fontSize(15)
            .backgroundColor($r('app.color.bg_page'))
            .borderRadius(20)
            .padding({ left: 16, right: 36 })
            .onChange((value: string) => {
              this.keyword = value;
            })
            .onSubmit(() => {
              this.doSearch();
            })

          if (this.keyword.trim().length > 0) {
            // 推荐写法：使用 SymbolGlyph（外套 40×40 标准点击体）
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(18)                 // 对应之前的 .width() .height()
                .fontColor([$r('app.color.text_disabled')])       // 注意：fontColor 接收数组
            }
            .width(40)
            .height(40)
            .margin({ right: 4 })
            .onClick(() => {
                this.keyword = '';
              })
          }
        }
        .layoutWeight(1)
        .margin({ left: 12, right: 12 })

        Stack() {
          Text('搜索')
            .fontSize(15)
            .fontColor($r('app.color.brand'))
            .fontWeight(FontWeight.Medium)
        }
        .width(40)
        .height(40)
        .onClick(() => this.doSearch())
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 12, right: 16, top: this.topSafeHeight + 4, bottom: 4 })
      .backgroundColor($r('app.color.header_bg'))
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.onPageReady(ctx);
    })
    .onBackPressed(() => this.onBackPress())
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
        .backgroundColor($r('app.color.bg_secondary'))

      // 信息区
      Column() {
        Text(album.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .constraintSize({ minHeight: 36 })
          .align(Alignment.Top)

        Row() {
          Text(album.author)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (album.totalViews && album.totalViews !== '0') {
            Text(`${album.totalViews} 次`)
              .fontSize(10)
              .fontColor($r('app.color.text_disabled'))
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
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(8)
    .shadow({
      radius: 4,
      color: $r('app.color.scrim'),
      offsetX: 0,
      offsetY: 2
    })
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function SearchPageBuilder() {
  SearchPage();
}
