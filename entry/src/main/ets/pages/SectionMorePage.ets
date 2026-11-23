import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiService } from '../network/ApiService';
import { JmAlbumInfo, albumToJmAlbumInfo } from '../models/Album';
import { RespJmAlbumInfo, JmPromoteSection } from '../models/dto/ApiDto';
import { ComicAlbum } from '../models/ComicAlbum';
import { FEED_HOME_LATEST, FEED_HOME_PROMOTE } from '../models/AlbumFeed';
import { AlbumDao } from '../storage/AlbumDao';
import { CacheManager } from '../common/CacheManager';
import { JmAlbumCard } from './JmAlbumCard';
import { MORE_FEED_PREFIX, SECTION_SOURCE_LATEST, SECTION_SOURCE_PROMOTE } from '../common/Constants';
import { navPop } from '../common/NavHelper';
// 参数形状复用中央定义（原本地 interface SectionMorePageParams）
import { SectionMoreParams } from '../common/RouteParams';

const MORE_TAG: string = 'SectionMore';

/**
 * 分区「更多」页
 * 初次进入直接展示首页已加载的分区数据（不重新请求），滑动到底部后再加载后续页
 */
@Component
struct SectionMorePage {
  @State albums: JmAlbumInfo[] = [];
  @State sectionTitle: string = '';
  // 初值 true：首次安装库为空时，读库这几毫秒也要有加载指示而不是空白
  @State isLoading: boolean = true;
  @State loadFailed: boolean = false;
  @State hasMore: boolean = true;
  // 首屏内容高度 / Scroll 可视高度，用于判断是否需要主动续加载
  @State contentHeight: number = 0;
  @State viewportHeight: number = 0;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private currentPage: number = 1;
  private source: string = '';
  private feedKey: string = '';
  private sectionKey: string = '';
  /** 更多页在库里的键前缀：more:{feedKey}:{sectionKey}:p */
  private morePrefix: string = '';
  private apiService: ApiService = ApiService.getInstance();
  /** 本地列表最近一次落库时间，用来判断是否过期 */
  private localUpdatedAt: number = 0;
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;
  @State showBackTop: boolean = false;
  /** 下拉刷新指示器：用户显式拉取，与首屏 isLoading 分开 */
  @State isRefreshing: boolean = false;
  private scroller: Scroller = new Scroller();
  private isBackTopScrolling: boolean = false;
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;

  // NavDestination 标准入口：参数与数据加载移入 onReady（原 router.getParams 时代在 aboutToAppear）
  private onPageReady(ctx: NavDestinationContext): void {
    let params = ctx.pathInfo.param as SectionMoreParams | null;
    if (params) {
      if (params.sectionTitle) {
        this.sectionTitle = params.sectionTitle;
      }
      if (params.feedKey) {
        this.feedKey = params.feedKey;
      }
      if (params.sectionKey) {
        this.sectionKey = params.sectionKey;
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
    if (!this.feedKey) {
      this.feedKey = this.source === SECTION_SOURCE_LATEST ? FEED_HOME_LATEST : FEED_HOME_PROMOTE;
    }
    if (!this.sectionKey) {
      this.sectionKey = this.feedKey;
    }
    this.morePrefix = `${MORE_FEED_PREFIX}${this.feedKey}:${this.sectionKey}:p`;
    this.loadFirst();
  }

  /** 首屏：先读库回放，本地缺失或过期才联网拉第 0 页 */
  private async loadFirst(): Promise<void> {
    let hasLocal = await this.renderFromStore();
    if (hasLocal && !this.isStale()) {
      this.isLoading = false;
      let pages = await this.loadedPageNumbers();
      // 首页分区即第 0 页；本地已有的更多页最大页码 +1 才是下一页
      this.currentPage = pages.length > 0 ? pages[pages.length - 1] + 1 : 1;
      return;
    }
    if (hasLocal) {
      // 过期：更多页作废，从第 0 页重拉（源列表分区的数据保留在首页 feed 里）
      this.isLoading = true;
      await AlbumDao.clearFeedPrefix(this.morePrefix);
      this.albums = [];
    }
    this.currentPage = 0;
    await this.loadAlbums();
  }

  /** 本地列表是否过期（间隔与开关都由设置页控制；更多页跟随首页） */
  private isStale(): boolean {
    return Date.now() - this.localUpdatedAt > CacheManager.feedTtlMsOf(CacheManager.REFRESH_HOME);
  }

  /** 从库里拼出整个列表：源列表分区（首屏）+ 已落库的更多页 */
  private async renderFromStore(): Promise<boolean> {
    let albums: ComicAlbum[] = [];
    let source = await AlbumDao.loadFeed(this.feedKey);
    this.localUpdatedAt = source.updatedAt;
    for (let section of source.sections) {
      if (section.key === this.sectionKey) {
        albums = albums.concat(section.albums);
        break;
      }
    }
    let pages = await this.loadedPageNumbers();
    for (let page of pages) {
      let snapshot = await AlbumDao.loadFeed(`${this.morePrefix}${page}`);
      if (snapshot.sections.length > 0) {
        this.localUpdatedAt = Math.max(this.localUpdatedAt, snapshot.updatedAt);
        albums = albums.concat(snapshot.sections[0].albums);
      }
    }
    this.albums = this.dedupeAlbums(albums.map((album: ComicAlbum) => albumToJmAlbumInfo(album)));
    return this.albums.length > 0;
  }

  /** 已落库的更多页页码，升序（用于恢复翻到了第几页） */
  private async loadedPageNumbers(): Promise<number[]> {
    return AlbumDao.feedPageNumbers(this.morePrefix);
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
    // 是否在加载由调用方（loadMore / tryAutoLoad）判断：这里不能再挡，
    // 否则首屏进网络分支时 isLoading 已是 true，会被自己拦死
    if (!this.hasMore) return;
    let page = this.currentPage;
    let pageKey = `${this.morePrefix}${page}`;
    // 1. 本地已有这一页：直接用，不联网
    let cached = await AlbumDao.loadFeed(pageKey);
    if (cached.sections.length > 0 && cached.sections[0].albums.length > 0) {
      await this.renderFromStore();
      this.currentPage = page + 1;
      this.isLoading = false;
      return;
    }
    // 2. 本地缺失才走网络
    this.isLoading = true;
    this.loadFailed = false;
    try {
      let items: RespJmAlbumInfo[] = [];
      if (this.source === SECTION_SOURCE_LATEST) {
        let resp = await this.apiService.getLatest(page);
        hilog.info(0, MORE_TAG, `latest page=${page} code=${resp.code} dataLen=${resp.data ? (resp.data as RespJmAlbumInfo[]).length : -1}`);
        if (resp.code === 200 && resp.data) {
          items = resp.data as RespJmAlbumInfo[];
        } else {
          this.loadFailed = true;
        }
      } else {
        let resp = await this.apiService.getPromote(page);
        let sections = resp.code === 200 && resp.data ? resp.data as JmPromoteSection[] : [];
        let matched = sections.filter((s: JmPromoteSection) => s.title === this.sectionTitle);
        hilog.info(0, MORE_TAG, `promote page=${page} code=${resp.code} sections=${sections.map((s: JmPromoteSection) => `${s.title}(${s.content ? s.content.length : 0})`).join('|')} matched=${matched.length}`);
        if (resp.code === 200 && resp.data) {
          for (let section of sections) {
            if (section.title === this.sectionTitle) {
              items = section.content || [];
              break;
            }
          }
        } else {
          this.loadFailed = true;
        }
      }
      if (this.loadFailed) return;
      if (items.length === 0) {
        this.hasMore = false;
        return;
      }
      // 3. 先落库，再从库读回来渲染
      let before = this.albums.length;
      await AlbumDao.saveFeed(pageKey, items, -1);
      await this.renderFromStore();
      this.currentPage = page + 1;
      if (this.albums.length <= before) {
        // 返回内容与已有数据完全重复（promote 接口不分页，翻页返回同内容），标记结束
        hilog.info(0, MORE_TAG, 'all duplicated, set hasMore=false');
        this.hasMore = false;
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
   * 下拉刷新：该分区从第 0 页重拉。
   * 与首页同款：不清 this.albums、不置 isLoading，旧内容留在屏上，
   * 落库后由 renderFromStore 整体替换。源分区留在首页 feed 里，不清。
   */
  private async pullRefresh(): Promise<void> {
    if (this.isPulling) {
      this.isRefreshing = false;
      return;
    }
    this.isPulling = true;
    try {
      let items: RespJmAlbumInfo[] | null = null;
      if (this.source === SECTION_SOURCE_LATEST) {
        let resp = await this.apiService.getLatest(0);
        if (resp.code === 200 && resp.data) {
          items = resp.data as RespJmAlbumInfo[];
        }
      } else {
        let resp = await this.apiService.getPromote(0);
        if (resp.code === 200 && resp.data) {
          items = [];
          for (let section of resp.data as JmPromoteSection[]) {
            if (section.title === this.sectionTitle) {
              items = section.content || [];
              break;
            }
          }
        }
      }
      if (items === null) {
        this.getUIContext().getPromptAction().showToast({ message: '刷新失败，已保留本地内容', duration: 2000 });
        return;
      }
      await AlbumDao.clearFeedPrefix(this.morePrefix);
      if (items.length > 0) {
        await AlbumDao.saveFeedKeepList(`${this.morePrefix}0`, items, -1);
      }
      this.currentPage = 1;
      this.hasMore = items.length > 0;
      await this.renderFromStore();
    } catch (err) {
      console.error('[SectionMorePage] pull refresh error:', JSON.stringify(err));
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
    }
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
    navPop();
  }

  onBackTop(): void {
    this.isBackTopScrolling = true;
    this.showBackTop = false;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 300, curve: Curve.EaseOut } });
  }

  build() {
    NavDestination() {
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
          Refresh({ refreshing: $$this.isRefreshing }) {
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
          .padding({ top: this.topSafeHeight + 56, bottom: this.bottomSafeHeight + 12 })
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

      // ── 顶部栏（浮层 + 毛玻璃） ──
      Row() {
        // 返回：40×40 标准点击体（与其他页统一；原 responseRegion 热区方案废弃，
        // 裸 SymbolGlyph 时代本页净高仅约 37vp，低于 mini 模式 48vp 下限）
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
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
      .padding({ left: 12, right: 16, top: this.topSafeHeight + 4, bottom: 4 })
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
        .position({ right: 20, bottom: this.bottomSafeHeight + 28 })
        .zIndex(9)
        .onClick(() => this.onBackTop())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.onPageReady(ctx);
    })
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function SectionMorePageBuilder() {
  SectionMorePage();
}
