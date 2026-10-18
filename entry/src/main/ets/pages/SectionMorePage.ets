import { router, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiService } from '../network/ApiService';
import {
  JmAlbumInfo, RespJmAlbumInfo, respToJmAlbumInfo,
  JmPromoteSection,
} from '../models/Album';
import { JmAlbumCard } from './JmAlbumCard';
import { SECTION_SOURCE_LATEST, SECTION_SOURCE_PROMOTE } from '../common/Constants';

const MORE_TAG: string = 'SectionMore';

interface SectionMorePageParams {
  sectionTitle: string;
  initialAlbums: RespJmAlbumInfo[];
  // 数据来源：latest / promote，由首页显式传入，避免依赖标题文案
  source?: string;
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
  // 首屏内容高度 / Scroll 可视高度，用于判断是否需要主动续加载
  @State contentHeight: number = 0;
  @State viewportHeight: number = 0;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  private currentPage: number = 1;
  private source: string = '';
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
        // 直接使用首页已加载的分区数据，无需重新请求；
        // 首屏同样要按 id 去重：ForEach 以 id 为 key，重复 id 会导致渲染异常
        let mapped = params.initialAlbums.map((item: RespJmAlbumInfo) => respToJmAlbumInfo(item));
        this.albums = this.dedupeAlbums(mapped);
      }
      // 优先使用首页显式传入的来源
      if (params.source) {
        this.source = params.source;
      }
    }
    if (!this.source) {
      // 兼容旧调用：未传 source 时按标题兜底推断
      this.source = this.sectionTitle === '最新上传' ? SECTION_SOURCE_LATEST : SECTION_SOURCE_PROMOTE;
    }
    // 首页数据对应第 0 页，后续从第 1 页继续加载
    this.currentPage = 1;
    // 无传入数据时（异常进入）从第 0 页拉取兜底
    if (this.albums.length === 0) {
      this.currentPage = 0;
      this.loadAlbums();
    }
  }

  /**
   * 首屏数据去重
   * - 丢弃 id 无效（<=0）的条目：这类条目无法打开详情，且会让 ForEach 的 id key 重复
   * - 同一 id 只保留首个，避免 ForEach key 冲突
   */
  private dedupeAlbums(list: JmAlbumInfo[]): JmAlbumInfo[] {
    let result: JmAlbumInfo[] = [];
    let seen = new Set<number>();
    for (let item of list) {
      if (item.id <= 0 || seen.has(item.id)) {
        continue;
      }
      seen.add(item.id);
      result.push(item);
    }
    return result;
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
            // 跳过无效 id，避免 ForEach key 变成 0；若整页都无效，下面会判定为没有更多
            if (album.id > 0) {
              map.set(album.id, album);
            }
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

  /**
   * 首屏内容不足一屏时，Scroll 的 onReachEnd 不会触发，导致无法续加载。
   * 布局完成后比较「内容高度」与「可视高度」，不足一屏就主动加载下一页；
   * 加载后内容变高会再次触发，直到填满一屏或没有更多。
   */
  private tryAutoLoad(): void {
    if (this.contentHeight <= 0 || this.viewportHeight <= 0) return;
    if (this.isLoading || !this.hasMore || this.loadFailed) return;
    // Scroll 的上下 padding 不参与内容区，计算可视高度时需要扣除
    let visible = this.viewportHeight - this.topSafeHeight - 76;
    // 留 2vp 容差，避免浮点误差导致反复触发
    if (visible > 0 && this.contentHeight <= visible + 2) {
      this.loadAlbums();
    }
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
              // 参考 SearchPage：Grid 按屏宽分列（手机 2 列 / 平板 4 列），
              // 卡片宽度由 1fr 自动均分，避免固定宽度造成两侧留白
              Grid() {
                ForEach(this.albums, (album: JmAlbumInfo) => {
                  GridItem() {
                    JmAlbumCard({ isTablet: this.isTablet, cardInfo: album, fillWidth: true })
                  }
                }, (album: JmAlbumInfo) => `${album.id}`)
              }
              .columnsTemplate(this.isTablet ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
              .columnsGap(12)
              .rowsGap(14)
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
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              this.contentHeight = Number(newArea.height);
              this.tryAutoLoad();
            })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .padding({ top: this.topSafeHeight + 56, bottom: 20 })
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            this.viewportHeight = Number(newArea.height);
            this.tryAutoLoad();
          })
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
