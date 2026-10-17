import { router, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiService } from '../network/ApiService';
import {
  JmAlbumInfo, RespJmAlbumInfo, respToJmAlbumInfo,
  JmPromoteSection,
} from '../models/Album';
import { JmAlbumCard } from './JmAlbumCard';

const MORE_TAG: string = 'SectionMore';

// 数据来源：最新上传 / 推荐分区
const SECTION_SOURCE_LATEST: string = 'latest';
const SECTION_SOURCE_PROMOTE: string = 'promote';

interface SectionMorePageParams {
  sectionTitle: string;
  initialAlbums: RespJmAlbumInfo[];
}

/**
 * 分区「更多」页
 * 初次进入直接展示首页已加载的分区数据（不重新请求），滑动到底部后再加载后续页
 */
@Entry
@Component
struct SectionMorePage {
  @State albums: JmAlbumInfo[] = [];
  @State sectionTitle: string = '';
  @State isLoading: boolean = false;
  @State loadFailed: boolean = false;
  @State hasMore: boolean = true;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  private currentPage: number = 1;
  private source: string = SECTION_SOURCE_PROMOTE;
  private apiService: ApiService = ApiService.getInstance();
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;
  @State showBackTop: boolean = false;
  private scroller: Scroller = new Scroller();
  private isBackTopScrolling: boolean = false;

  aboutToAppear(): void {
    let params = router.getParams() as SectionMorePageParams;
    if (params) {
      if (params.sectionTitle) {
        this.sectionTitle = params.sectionTitle;
      }
      if (params.initialAlbums && params.initialAlbums.length > 0) {
        // 直接使用首页已加载的分区数据，无需重新请求
        this.albums = params.initialAlbums.map((item: RespJmAlbumInfo) => respToJmAlbumInfo(item));
      }
    }
    this.source = this.sectionTitle === '最新上传' ? SECTION_SOURCE_LATEST : SECTION_SOURCE_PROMOTE;
    // 首页数据对应第 0 页，后续从第 1 页继续加载
    this.currentPage = 1;
    // 无传入数据时（异常进入）从第 0 页拉取兜底
    if (this.albums.length === 0) {
      this.currentPage = 0;
      this.loadAlbums();
    }
  }

  async loadAlbums(): Promise<void> {
    if (this.isLoading || !this.hasMore) return;
    this.isLoading = true;
    this.loadFailed = false;
    let newItems: JmAlbumInfo[] = [];
    try {
      if (this.source === SECTION_SOURCE_LATEST) {
        let resp = await this.apiService.getLatest(this.currentPage);
        hilog.info(0, MORE_TAG, `latest page=${this.currentPage} code=${resp.code} dataLen=${resp.data ? (resp.data as RespJmAlbumInfo[]).length : -1}`);
        if (resp.code === 200 && resp.data) {
          let list = resp.data as RespJmAlbumInfo[];
          newItems = list.map((item: RespJmAlbumInfo) => respToJmAlbumInfo(item));
        } else {
          this.loadFailed = true;
        }
      } else {
        let resp = await this.apiService.getPromote(this.currentPage);
        let sections = resp.code === 200 && resp.data ? resp.data as JmPromoteSection[] : [];
        let matched = sections.filter((s: JmPromoteSection) => s.title === this.sectionTitle);
        hilog.info(0, MORE_TAG, `promote page=${this.currentPage} code=${resp.code} sections=${sections.map((s: JmPromoteSection) => `${s.title}(${s.content ? s.content.length : 0})`).join('|')} matched=${matched.length}`);
        if (resp.code === 200 && resp.data) {
          for (let section of sections) {
            if (section.title === this.sectionTitle) {
              let list = section.content || [];
              newItems = list.map((item: RespJmAlbumInfo) => respToJmAlbumInfo(item));
              break;
            }
          }
        } else {
          this.loadFailed = true;
        }
      }
      if (!this.loadFailed) {
        if (newItems.length > 0) {
          // 去重合并：避免 ForEach key 重复
          let map = new Map<number, JmAlbumInfo>();
          for (let album of this.albums) {
            map.set(album.id, album);
          }
          let before = map.size;
          for (let album of newItems) {
            map.set(album.id, album);
          }
          if (map.size > before) {
            this.albums = Array.from(map.values());
            this.currentPage++;
          } else {
            // 返回内容与已有数据完全重复（promote 接口不分页，翻页返回同内容），标记结束
            hilog.info(0, MORE_TAG, `all duplicated, set hasMore=false`);
            this.hasMore = false;
          }
        } else {
          this.hasMore = false;
        }
      }
    } catch (err) {
      console.error('[SectionMorePage] load error:', JSON.stringify(err));
      this.loadFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  loadMore(): void {
    hilog.info(0, MORE_TAG, `loadMore triggered: isLoading=${this.isLoading} hasMore=${this.hasMore} loadFailed=${this.loadFailed} currentPage=${this.currentPage} albums=${this.albums.length}`);
    if (this.isLoading || !this.hasMore || this.loadFailed) return;
    this.loadAlbums();
  }

  onBack(): void {
    router.back();
  }

  onBackTop(): void {
    this.isBackTopScrolling = true;
    this.showBackTop = false;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 300, curve: Curve.EaseOut } });
  }

  build() {
    Stack() {
      // ── 内容区域 ──
      Column() {
        if (this.albums.length === 0 && this.isLoading) {
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
        } else if (this.albums.length === 0 && this.loadFailed) {
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
              .onClick(() => this.loadAlbums())
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.albums.length === 0) {
          Column() {
            Text('暂无数据')
              .fontSize(16)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.scroller) {
            Column() {
              // 卡片流式铺排：不固定每行个数，按卡片宽度自动换行，每行水平居中
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
                ForEach(this.albums, (album: JmAlbumInfo) => {
                  JmAlbumCard({ isTablet: this.isTablet, cardInfo: album })
                    .margin({ left: 6, right: 6, bottom: 14 })
                }, (album: JmAlbumInfo) => `${album.id}`)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 10, bottom: 6 })

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
              } else if (this.loadFailed) {
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
                .onClick(() => this.loadAlbums())
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
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .padding({ top: this.topSafeHeight + 56, bottom: 20 })
          .onReachEnd(() => this.loadMore())
          .onDidScroll(() => {
            if (this.isBackTopScrolling) return;
            // 下滑超过 400vp 后显示回顶按钮
            this.showBackTop = this.scroller.currentOffset().yOffset > 400;
          })
          .onScrollStop(() => {
            // 回顶动画结束（或被打断）后解除屏蔽，交还给正常滑动逻辑
            if (this.isBackTopScrolling) {
              this.isBackTopScrolling = false;
              this.showBackTop = false;
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_card'))

      // ── 顶部栏（浮层 + 毛玻璃） ──
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.text_primary')])
          // 扩大点击热区：上/左各扩 12vp，下扩 10vp，左右共 48vp 宽。
          // 扩展后底边距首个卡片顶部仍有 24vp 以上间距，不影响其响应
          .responseRegion({ x: -18, y: -12, width: 48, height: 46 })
          .onClick(() => this.onBack())

        Text(this.sectionTitle)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
          .layoutWeight(1)
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 12, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor($r('app.color.header_bg'))
      .backdropBlur(20)
      .zIndex(10)

      // ── 回到顶部按钮（悬浮，下滑后显示） ──
      if (this.showBackTop) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_up'))
            .fontSize(20)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor($r('app.color.overlay_bg'))
        .backdropBlur(20)
        .shadow({ radius: 8, color: '#1A000000', offsetX: 0, offsetY: 2 })
        .position({ right: 20, bottom: 48 })
        .zIndex(9)
        .onClick(() => this.onBackTop())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
