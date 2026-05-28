import { router, display } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import { AlbumViewModel, JmAlbumInfo, IAlbumViewModelJSON } from '../models/Album';
import { CacheManager } from '../common/CacheManager';

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State albums: AlbumViewModel[] = [];
  @State isLoading: boolean = false;
  @State hasSearched: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = false;
  @State searchHistory: string[] = [];
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = new ApiService();
  private cache: CacheManager | null = null;
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    this.searchHistory = this.cache.getSearchHistory();
    let params = router.getParams() as Record<string, string>;
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
          router.pushUrl({
            url: 'pages/AlbumDetailPage',
            params: { albumId: parseInt(kw), albumName: resp.data.name || '' }
          });
        } else {
          console.error(`[SearchPage] album id=${kw} not found: ${resp.message}`);
        }
      } catch (err) {
        console.error(`[SearchPage] album id=${kw} error: ${JSON.stringify(err)}`);
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

    // 尝试加载缓存
    if (this.cache) {
      let cached = this.cache.loadSearchResult(kw, this.currentPage);
      if (cached) {
        let items = AlbumViewModel.fromJSONArray(JSON.parse(cached.data) as IAlbumViewModelJSON[]);
        if (isNewSearch) {
          this.albums = items;
        } else {
          this.albums = this.albums.concat(items);
        }
        this.hasMore = items.length >= 20;
        return;
      }
    }

    this.isLoading = true;

    try {
      let resp = await this.apiService.search(kw, this.currentPage);

      if (resp.code === 200 && resp.data) {
        let list = resp.data.content;
        let vms = list.map(item => {
          let vm = AlbumViewModel.fromApiInfo(item, '');
          vm.coverUrl = this.apiService.buildCoverUrl(vm.id);
          return vm;
        });

        if (isNewSearch) {
          this.albums = vms;
        } else {
          this.albums = this.albums.concat(vms);
        }

        this.hasMore = vms.length >= 20;

        // 保存搜索结果缓存
        if (this.cache) {
          let data = JSON.stringify(vms.map(vm => vm.toJSON()));
          this.cache.saveSearchResult(kw, this.currentPage, data, parseInt(resp.data.total) || 0);
        }
      }
    } catch (err) {
      console.error('search error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  loadMore(): void {
    if (!this.hasMore || this.isLoading) return;
    this.currentPage++;
    this.doSearch(false);
  }

  onAlbumClick(album: AlbumViewModel): void {
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: { albumId: album.id, albumName: album.name }
    });
  }

  onBack(): void {
    if (this.hasSearched) {
      this.hasSearched = false;
      this.albums = [];
      this.currentPage = 1;
      this.hasMore = false;
    } else {
      router.back();
    }
  }

  onBackPress(): boolean {
    if (this.hasSearched) {
      this.onBack();
      return true;
    }
    return false;
  }

  build() {
    Stack() {
      // ── 内容区域（延伸到搜索栏背后） ──
      Column() {
        // ── 结果区域 ──
        if (this.isLoading && this.albums.length === 0) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#FF5A5F')
            Text('搜索中...')
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.hasSearched && this.albums.length === 0) {
          Column() {
            Image($r('sys.symbol.magnifyingglass'))
              .width(48)
              .height(48)
              .fillColor('#CCCCCC')
            Text('未找到相关漫画')
              .fontSize(16)
              .fontColor('#999999')
              .margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (!this.hasSearched) {
          Column() {
            if (this.searchHistory.length > 0) {
              // 搜索历史
              Column() {
                Row() {
                  Text('搜索历史')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333')
                    .layoutWeight(1)

                  Text('清空')
                    .fontSize(13)
                    .fontColor('#999999')
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
                      .fontColor('#666666')
                      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                      .backgroundColor('#F5F5F5')
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
              Image($r('sys.symbol.magnifyingglass'))
                .width(48)
                .height(48)
                .fillColor('#DDDDDD')
              Text('输入关键词搜索漫画')
                .fontSize(15)
                .fontColor('#BBBBBB')
                .margin({ top: 12 })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .padding({ top: this.topSafeHeight + 56 })
        } else {
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
                    .color('#FF5A5F')
                  Text('加载更多...')
                    .fontSize(13)
                    .fontColor('#999999')
                    .margin({ left: 8 })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 16, bottom: 16 })
              } else if (!this.hasMore) {
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
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .padding({ top: this.topSafeHeight + 56 })
          .onReachEnd(() => this.loadMore())
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')

      // ── 搜索栏（浮层 + 毛玻璃） ──
      Row() {
        Image($r('sys.symbol.chevron_left'))
          .width(24)
          .height(24)
          .fillColor('#333333')
          .onClick(() => this.onBack())

        TextInput({ placeholder: '输入关键词搜索...', text: this.keyword })
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .backgroundColor('#F5F5F5')
          .borderRadius(20)
          .padding({ left: 16, right: 16 })
          .margin({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => {
            this.doSearch();
          })

        Text('搜索')
          .fontSize(15)
          .fontColor('#FF5A5F')
          .fontWeight(FontWeight.Medium)
          .onClick(() => this.doSearch())
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 12, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
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
