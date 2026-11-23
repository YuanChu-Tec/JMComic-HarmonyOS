import { display, uiMaterial } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import {
  AlbumViewModel, JmAlbumInfo, albumToJmAlbumInfo, respToJmAlbumInfo
} from '../models/Album';
import { parseCommentRaw } from '../models/ComicAlbum';
import { JmPromoteSection, SearchResultData, CommentPageData, CommentInfoRaw,
  FavoriteFolderItem, FavoriteAlbumItem, RespJmAlbumInfo,
} from '../models/dto/ApiDto';
import { CacheManager } from '../common/CacheManager';
import {
  CATEGORY_ALL, CATEGORY_DOUJIN, CATEGORY_SINGLE, CATEGORY_SHORT,
  CATEGORY_ANOTHER, CATEGORY_HANMAN, CATEGORY_MEIMAN,
  CATEGORY_DOUJIN_COSPLAY, CATEGORY_3D, CATEGORY_ENGLISH_SITE,
  CATEGORY_NAME_MAP, ORDER_BY_LATEST, ORDER_MONTH_RANKING,
  ORDER_WEEK_RANKING, ORDER_DAY_RANKING, ORDER_BY_LIKE,
  ORDER_NAME_MAP, PAGE_SIZE_FAVORITE,
  MORE_FEED_PREFIX, SECTION_SOURCE_LATEST, SECTION_SOURCE_PROMOTE,
} from '../common/Constants';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { CommentItemComponent } from '../common/CommentItem';
import { DeviceUtils } from 'common';
import { AccountManager, ActiveCredentials } from '../common/AccountManager';
import { ComicLibrary, CleanupRule } from '../common/ComicLibrary';
import { ComicAlbum, CommentInfo, COMMENT_MODE_ALL, COMMENT_MODE_MANHUA, COMMENT_MODE_CHAT,
  COMMENT_MODE_NAME_MAP } from '../models/ComicAlbum';
import { FEED_HOME_LATEST, FEED_HOME_PROMOTE } from '../models/AlbumFeed';
import { AlbumDao } from '../storage/AlbumDao';
import { JmAlbumCard } from './JmAlbumCard';
import { navPush } from '../common/NavHelper';
import { AlbumDetailParams, SectionMoreParams } from '../common/RouteParams';

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
/** 首页一个推广分区：标题 + 卡片的显示数据（全部来自库） */
interface PromoteSectionVM {
  key: string;
  title: string;
  albums: JmAlbumInfo[];
}

@Component
struct HomePage {
  @State sections: PromoteSectionVM[] = [];
  @State latestAlbums: JmAlbumInfo[] = [];
  @State isLoading: boolean = true;
  @State loadFailed: boolean = false;
  /** 下拉刷新指示器：只表示用户手动拉取中，与首屏 isLoading 分开 */
  @State isRefreshing: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  /** 设置页改了刷新间隔 / 切回首页时递增，按新的 TTL 重新判断 */
  @StorageProp('feedRefreshTick') @Watch('onFeedRefreshTick') feedRefreshTick: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;
  /** 本地数据的落库时间，用来判断要不要刷新 */
  private localUpdatedAt: number = 0;
  /** 刷新代号：每发起一轮 +1，晚到的旧响应据此丢弃，避免乱序落库把列表换回去 */
  private feedSeq: number = 0;
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;

  async aboutToAppear(): Promise<void> {
    console.info('[HomePage] aboutToAppear');
    await this.loadData();
  }

  /** 本地优先：有本地数据先渲染，缺失或过期才联网 */
  async loadData(): Promise<void> {
    this.loadFailed = false;
    try {
      let hasLocal = await this.renderFromStore();
      console.info(`[HomePage] hasLocal=${hasLocal}, updatedAt=${this.localUpdatedAt}, stale=${this.isStale()}`);
      this.isLoading = !hasLocal;
      if (hasLocal && !this.isStale()) {
        return;
      }
      await this.refresh();
    } catch (err) {
      // 读库本身出错时不会进 refresh，这里兜底，避免界面永远停在加载中
      console.error('[HomePage] loadData error:', JSON.stringify(err));
      this.isLoading = false;
      this.loadFailed = true;
    }
  }

  /** 本地是否过期：落库时间早于 TTL（间隔与开关都由设置页控制） */
  private isStale(): boolean {
    return Date.now() - this.localUpdatedAt > CacheManager.feedTtlMsOf(CacheManager.REFRESH_HOME);
  }

  onFeedRefreshTick(): void {
    if (this.isLoading) return;
    this.loadData();
  }

  /** 从库里读并渲染，返回本地是否有可显示内容 */
  private async renderFromStore(): Promise<boolean> {
    let latest = await AlbumDao.loadFeed(FEED_HOME_LATEST);
    let promote = await AlbumDao.loadFeed(FEED_HOME_PROMOTE);
    let latestAlbums: JmAlbumInfo[] = [];
    if (latest.sections.length > 0) {
      latestAlbums = latest.sections[0].albums.map((album: ComicAlbum) => albumToJmAlbumInfo(album));
    }
    let sections: PromoteSectionVM[] = [];
    for (let section of promote.sections) {
      if (section.albums.length === 0) continue;
      // /promote 的首段常常也叫「最新上传」，而首页顶部已经用 /latest 单独渲染了它。
      // 两块同名列表来自两个接口、内容并不一致，会让人以为「最新上传」在不停切换。
      if (section.title === '最新上传') continue;
      sections.push({
        key: section.key,
        title: section.title,
        albums: section.albums.map((album: ComicAlbum) => albumToJmAlbumInfo(album)),
      });
    }
    this.latestAlbums = latestAlbums;
    this.sections = sections;
    this.localUpdatedAt = Math.max(latest.updatedAt, promote.updatedAt);
    return latestAlbums.length > 0 || sections.length > 0;
  }

  /** 联网刷新：响应先落库，再从库读回来渲染 */
  private async refresh(): Promise<void> {
    let seq = ++this.feedSeq;
    try {
      let results = await Promise.all([
        this.apiService.getPromote(),
        this.apiService.getLatest()
      ]);
      let promoteResp = results[0];
      let latestResp = results[1];
      // 请求期间又发起了更新的一轮：这轮的响应已过期，不能覆盖库和界面
      if (seq !== this.feedSeq) {
        return;
      }
      if (promoteResp.code === 200 && promoteResp.data) {
        await AlbumDao.savePromoteFeed(FEED_HOME_PROMOTE, promoteResp.data as JmPromoteSection[]);
      }
      if (latestResp.code === 200 && latestResp.data) {
        // 最新上传的接口不给总数，total 记 -1（未知）
        await AlbumDao.saveFeed(FEED_HOME_LATEST, latestResp.data as RespJmAlbumInfo[], -1);
      }
      if (!await this.renderFromStore()) {
        this.loadFailed = true;
      }
    } catch (err) {
      console.error('[HomePage] load error:', JSON.stringify(err));
      // 本地已有内容时不打扰用户，只有全空才提示加载失败
      this.loadFailed = this.latestAlbums.length === 0 && this.sections.length === 0;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 下拉刷新：只重建列表成员与顺序，用来拉新漫画。
   * - 不走 TTL、不看「首页」范围开关：这是用户的显式动作
   * - 不覆盖已有作品的字段与封面：那是「刷新内容」与自动刷新的职责
   */
  private async pullRefresh(): Promise<void> {
    if (this.isLoading) {
      // 首屏还在加载，这次下拉不并发写库
      this.isRefreshing = false;
      return;
    }
    if (this.isPulling) {
      // 上一轮还没落库完：忽略这次触发，指示器跟着已在跑的那轮走
      return;
    }
    this.isPulling = true;
    let seq = ++this.feedSeq;
    try {
      let results = await Promise.all([
        this.apiService.getPromote(),
        this.apiService.getLatest()
      ]);
      let promoteResp = results[0];
      let latestResp = results[1];
      // 请求期间又发起了更新的一轮：这轮的响应已过期，不能覆盖库和界面
      if (seq !== this.feedSeq) {
        return;
      }
      let landed = false;
      if (promoteResp.code === 200 && promoteResp.data) {
        await AlbumDao.savePromoteFeedKeepList(FEED_HOME_PROMOTE, promoteResp.data as JmPromoteSection[]);
        landed = true;
      }
      if (latestResp.code === 200 && latestResp.data) {
        // 最新上传的接口不给总数，total 记 -1（未知）
        await AlbumDao.saveFeedKeepList(FEED_HOME_LATEST, latestResp.data as RespJmAlbumInfo[], -1);
        landed = true;
      }
      if (landed) {
        // 源列表成员变了，分区「更多」的旧分页不再对应同一份列表
        await AlbumDao.clearFeedPrefix(MORE_FEED_PREFIX);
        await this.renderFromStore();
      } else {
        this.showToast('刷新失败，已保留本地内容');
      }
    } catch (err) {
      console.error('[HomePage] pull refresh error:', JSON.stringify(err));
      this.showToast('刷新失败，已保留本地内容');
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      console.warn('[HomePage] toast error:', JSON.stringify(e));
    }
  }

  onSectionMore(title: string, feedKey: string, sectionKey: string, source: string): void {
    navPush('SectionMorePage', {
      sectionTitle: title, feedKey: feedKey, sectionKey: sectionKey, source: source
    } as SectionMoreParams);
  }

  @Builder
  SectionMoreEntry(title: string, feedKey: string, sectionKey: string, source: string) {
    Row({ space: 2 }) {
      Text('更多')
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .onClick(() => this.onSectionMore(title, feedKey, sectionKey, source))
  }

  build() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      Scroll() {
        Column() {
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
            .height(300)
            .justifyContent(FlexAlign.Center)
          } else if (this.loadFailed && this.sections.length === 0 && this.latestAlbums.length === 0) {
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
                .onClick(() => this.loadData())
            }
            .width('100%')
            .height(300)
            .justifyContent(FlexAlign.Center)
          } else if (this.sections.length === 0 && this.latestAlbums.length === 0) {
            Column() {
              Text('暂无数据')
                .fontSize(16)
                .fontColor($r('app.color.text_tertiary'))
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
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)

                  this.SectionMoreEntry('最新上传', FEED_HOME_LATEST, FEED_HOME_LATEST, SECTION_SOURCE_LATEST)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 16, bottom: 10 })

                Scroll() {
                  Row({ space: 10 }) {
                    ForEach(this.latestAlbums, (album: JmAlbumInfo) => {
                      JmAlbumCard({ isTablet: this.isTablet, cardInfo: album })
                    }, (album: JmAlbumInfo) => {
                      return `${album.id}`
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
            ForEach(this.sections, (section: PromoteSectionVM) => {
              Column() {
                // 分区标题
                Row() {
                  Text(section.title)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)

                  // 传入当前推广分区自身的标识，不能用「最新上传」，
                  // 否则所有分区的更多页都会展示最新上传数据并走错分页接口
                  this.SectionMoreEntry(section.title, FEED_HOME_PROMOTE, section.key, SECTION_SOURCE_PROMOTE)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 16, bottom: 10 })

                // 横向滑动列表
                Scroll() {
                  Row({ space: 10 }) {
                    ForEach(section.albums, (album: JmAlbumInfo) => {
                      JmAlbumCard({isTablet: this.isTablet, cardInfo: album})
                    }, (album: JmAlbumInfo) => {
                      return `${album.id}`
                    })
                  }
                  .padding({ left: 16, right: 16 })
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%')
              }
            }, (section: PromoteSectionVM) => section.key)
          }
        }
        .width('100%')
        .padding({ top: this.topSafeHeight + 64, bottom: this.bottomSafeHeight + 100 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .backgroundColor($r('app.color.bg_page'))
    }
    .onRefreshing(() => {
      this.pullRefresh();
    })
    .width('100%')
    .height('100%')
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
  /** 冷启动静默复验中：期间不发起需要登录的请求，避免拿未验证的会话打空枪 */
  @StorageProp('sessionPending') @Watch('onSessionPendingChanged') sessionPending: boolean = false;
  @StorageProp('activeUsername') @Watch('onActiveUserChanged') activeUsername: string = '';
  /** 设置页改了刷新间隔 / 切回个人中心时递增，按新的 TTL 重新判断 */
  @StorageProp('feedRefreshTick') @Watch('onFeedRefreshTick') feedRefreshTick: number = 0;
  /** 收藏 / 历史各自最近一次落库时间 */
  private favLocalUpdatedAt: number = 0;
  private watchLocalUpdatedAt: number = 0;
  @State favAlbums: AlbumViewModel[] = [];
  @State favFolders: FavoriteFolderItem[] = [];
  @State favCurrentFolderId: string = '0';
  @State favIsLoading: boolean = false;
  @State favCurrentPage: number = 1;
  @State favHasMore: boolean = true;
  @State favTotal: number = 0;
  @State favNeedLoad: boolean = false;
  @State favLoadFailed: boolean = false;
  @State watchTotal: number = 0;
  @State watchLoadFailed: boolean = false;
  @State watchAlbums: AlbumViewModel[] = [];
  @State watchIsLoading: boolean = false;
  @State watchCurrentPage: number = 1;
  @State watchHasMore: boolean = true;
  // 历史管理态：长按进入，复选框多选，底部胶囊承载删除/取消
  @State watchSelectMode: boolean = false;
  @State watchSelectedIds: Set<string> = new Set<string>();
  @State isDeleting: boolean = false;
  /** 下拉刷新指示器：只在登录态下由用户手动触发 */
  @State isRefreshing: boolean = false;
  private tabsController: TabsController = new TabsController();
  private outerScroller: Scroller = new Scroller();
  private apiService: ApiService = ApiService.getInstance();
  private cache: CacheManager | null = null;
  private loadedUsername: string = '';
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  async aboutToAppear(): Promise<void> {
    AppStorage.setOrCreate('isLoggedIn', this.apiService.isLoggedIn());
    this.cache = await CacheManager.getInstance();
    // 按当前会话用户加载收藏/历史（多账号切换时按用户去重刷新）
    this.ensureLoadedForUser();
  }

  /** 组件销毁兜底：管理态若未退出，停掉握姿监听防泄漏 */
  aboutToDisappear(): void {
    this.exitWatchSelectMode();
  }

  /** 当isLoggedIn变化时（自动登录完成/退出登录），加载或清空用户数据 */
  onLoginStateChanged(): void {
    if (this.isLoggedIn) {
      this.ensureLoadedForUser();
    } else {
      // 登出时若处于历史管理态，对称停掉握姿监听
      this.exitWatchSelectMode();
      this.loadedUsername = '';
      this.resetUserData();
    }
  }

  /** 活跃账号变化（切换/新增账号）时刷新收藏/历史 */
  onActiveUserChanged(): void {
    if (this.isLoggedIn) {
      this.ensureLoadedForUser();
    }
  }

  /**
   * 静默复验结束才真正加载：复验前恢复的会话可能已被服务端作废，
   * 此时先按失效 cookie 去拉收藏/历史只会白跑一趟并闪「加载失败」。
   */
  onSessionPendingChanged(): void {
    if (!this.sessionPending && this.isLoggedIn) {
      this.ensureLoadedForUser();
    }
  }

  /** 同一账号仅加载一次；账号变更时重置列表并重新加载 */
  private ensureLoadedForUser(): void {
    if (this.sessionPending) return;
    let username = this.apiService.getUserSession().username;
    if (!username || this.loadedUsername === username) return;
    this.loadedUsername = username;
    // 账号切换前退出管理态：防旧账号选中集残留导致跨账号误删
    this.exitWatchSelectMode();
    this.resetUserData();
    this.favNeedLoad = true;
    this.loadFavorites();
    this.loadWatchCount();
    this.loadWatchHistory();
  }

  private resetUserData(): void {
    this.favAlbums = [];
    this.favFolders = [];
    this.favCurrentFolderId = '0';
    this.favCurrentPage = 1;
    this.favHasMore = true;
    this.favTotal = 0;
    this.favNeedLoad = false;
    this.favLoadFailed = false;
    this.watchAlbums = [];
    this.watchTotal = 0;
    this.watchCurrentPage = 1;
    this.watchHasMore = true;
    this.watchLoadFailed = false;
  }

  async loadWatchCount(): Promise<void> {
    // 本地优先：已落库的历史页足够给出条数
    let snapshots = await AlbumDao.loadFeedPages(this.watchPrefix());
    let count = 0;
    for (let snapshot of snapshots) {
      if (snapshot.sections.length > 0) {
        count += snapshot.sections[0].albums.length;
      }
    }
    if (count > 0) {
      this.watchTotal = count;
      return;
    }
    // 本地缺失才走网络
    try {
      let resp = await this.apiService.getWatchList(1);
      if (resp.code === 200 && resp.data) {
        this.watchTotal = resp.data.list.length;
        console.info('[ProfilePage] loadWatchCount done, count:', this.watchTotal);
      } else {
        console.warn('[ProfilePage] loadWatchCount bad resp:', resp.code);
      }
    } catch (err) {
      console.warn('[ProfilePage] load watch count error:', JSON.stringify(err));
    }
  }

  async onLogin(): Promise<void> {
    if (!this.isLoggedIn) {
      navPush('LoginPage');
    }
  }

  /** 进入账号管理页（切换/添加账号、退出登录） */
  onOpenAccountManage(): void {
    navPush('AccountManagePage');
  }

  /** 进入设置页（黑白模式、清理缓存等） */
  onOpenSettings(): void {
    navPush('SettingsPage');
  }

  /** 进入下载管理页（后台下载队列与导出压缩包） */
  onOpenDownloads(): void {
    navPush('DownloadPage');
  }

  /** 当前收藏夹在库里的分页前缀（按账号隔离，避免多账号串数据） */
  private favPrefix(): string {
    return `fav:${this.loadedUsername}:${this.favCurrentFolderId}:p`;
  }

  /** 从库里读出该收藏夹的全部已落库页并渲染 */
  private async renderFavoritesFromStore(): Promise<boolean> {
    let snapshots = await AlbumDao.loadFeedPages(this.favPrefix());
    let albums: AlbumViewModel[] = [];
    this.favLocalUpdatedAt = 0;
    for (let snapshot of snapshots) {
      this.favLocalUpdatedAt = Math.max(this.favLocalUpdatedAt, snapshot.updatedAt);
      if (snapshot.sections.length === 0) continue;
      for (let album of snapshot.sections[0].albums) {
        albums.push(AlbumViewModel.fromAlbum(album,
          this.apiService.coverSource(album.id, '_3x4', album.imageName)));
      }
    }
    this.favAlbums = albums;
    if (this.cache) {
      let folders = this.cache.loadFavoriteFolders(this.loadedUsername);
      if (folders.length > 0) {
        this.favFolders = folders;
      }
    }
    return albums.length > 0;
  }

  /** 收藏项 → 列表项（字段与 RespJmAlbumInfo 兼容，落库用） */
  private favoriteToInfo(item: FavoriteAlbumItem): RespJmAlbumInfo {
    return {
      id: item.id,
      name: item.name,
      author: item.author,
      image: item.image,
      description: item.description,
      category: item.category,
    };
  }

  async loadFavorites(): Promise<void> {
    if (this.favIsLoading) return;
    // 一进函数就置加载态：读库这几毫秒也别让用户看到"还没有收藏"
    this.favIsLoading = true;
    this.favLoadFailed = false;
    let prefix = this.favPrefix();
    let page = this.favCurrentPage;
    // 1. 本地优先：首页回放全部已落库页，翻页只看这一页在不在
    if (page === 1) {
      let hasLocal = await this.renderFavoritesFromStore();
      if (hasLocal && !this.isFavStale()) {
        let pages = await AlbumDao.feedPageNumbers(prefix);
        this.favCurrentPage = pages.length > 0 ? pages[pages.length - 1] : 1;
        this.favNeedLoad = false;
        this.favIsLoading = false;
        return;
      }
      if (hasLocal) {
        // 过期：收藏夹整体作废，从第一页重拉
        await AlbumDao.clearFeedPrefix(prefix);
        this.favAlbums = [];
        this.favCurrentPage = 1;
        page = 1;
      }
    } else {
      let cached = await AlbumDao.loadFeed(`${prefix}${page}`);
      if (cached.sections.length > 0 && cached.sections[0].albums.length > 0) {
        await this.renderFavoritesFromStore();
        this.favHasMore = cached.sections[0].albums.length >= PAGE_SIZE_FAVORITE;
        this.favIsLoading = false;
        return;
      }
    }
    // 2. 本地缺失才走网络
    try {
      let resp = await this.apiService.getFavorites(page, this.favCurrentFolderId);
      if (resp.code === 200 && resp.data) {
        let pageData = resp.data;
        this.favTotal = pageData.total;
        // 3. 先落库（收藏夹清单单独存一条），再从库读回来渲染
        let items: RespJmAlbumInfo[] = pageData.list.map((item: FavoriteAlbumItem) => this.favoriteToInfo(item));
        await AlbumDao.saveFeed(`${prefix}${page}`, items, pageData.total);
        if (this.cache) {
          this.cache.saveFavoriteFolders(this.loadedUsername, pageData.folder_list || []);
        }
        await this.renderFavoritesFromStore();
        this.favHasMore = pageData.list.length >= PAGE_SIZE_FAVORITE;
      }
    } catch (err) {
      console.error('[ProfilePage] loadFavorites error:', JSON.stringify(err));
      this.favLoadFailed = true;
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

  /** 观看历史在库里的分页前缀（按账号隔离） */
  private watchPrefix(): string {
    return `watch:${this.loadedUsername}:p`;
  }

  /** 从库里读出全部已落库的历史页并渲染 */
  private async renderWatchFromStore(): Promise<boolean> {
    let snapshots = await AlbumDao.loadFeedPages(this.watchPrefix());
    let albums: AlbumViewModel[] = [];
    this.watchLocalUpdatedAt = 0;
    for (let snapshot of snapshots) {
      this.watchLocalUpdatedAt = Math.max(this.watchLocalUpdatedAt, snapshot.updatedAt);
      if (snapshot.sections.length === 0) continue;
      for (let album of snapshot.sections[0].albums) {
        albums.push(AlbumViewModel.fromAlbum(album,
          this.apiService.coverSource(album.id, '_3x4', album.imageName)));
      }
    }
    this.watchAlbums = albums;
    this.watchTotal = albums.length;
    return albums.length > 0;
  }

  /** 收藏 / 历史本地数据是否过期（间隔与开关都由设置页控制） */
  private isFavStale(): boolean {
    return Date.now() - this.favLocalUpdatedAt > CacheManager.feedTtlMsOf(CacheManager.REFRESH_PROFILE);
  }

  private isWatchStale(): boolean {
    return Date.now() - this.watchLocalUpdatedAt > CacheManager.feedTtlMsOf(CacheManager.REFRESH_PROFILE);
  }

  onFeedRefreshTick(): void {
    if (!this.isLoggedIn) return;
    this.loadFavorites();
    this.loadWatchHistory();
  }

  /**
   * 下拉刷新：收藏与历史都从第一页重拉。
   * 未登录时没有可刷新的数据，直接收掉指示器，不发请求。
   * 与首页同款：不清 favAlbums / watchAlbums，也不置 favIsLoading / watchIsLoading，
   * 旧内容留在屏上，落库后由 renderXxxFromStore 整体替换。
   */
  private async pullRefresh(): Promise<void> {
    if (!this.isLoggedIn || this.isPulling) {
      this.isRefreshing = false;
      return;
    }
    this.isPulling = true;
    let failed = true;
    try {
      let favPrefix = this.favPrefix();
      let favResp = await this.apiService.getFavorites(1, this.favCurrentFolderId);
      if (favResp.code === 200 && favResp.data) {
        let pageData = favResp.data;
        let items: RespJmAlbumInfo[] = pageData.list.map((item: FavoriteAlbumItem) => this.favoriteToInfo(item));
        // 旧分页不再对应这份收藏夹，整批作废后只写新的第一页
        await AlbumDao.clearFeedPrefix(favPrefix);
        await AlbumDao.saveFeedKeepList(`${favPrefix}1`, items, pageData.total);
        this.favTotal = pageData.total;
        this.favCurrentPage = 1;
        this.favHasMore = pageData.list.length >= PAGE_SIZE_FAVORITE;
        if (this.cache) {
          this.cache.saveFavoriteFolders(this.loadedUsername, pageData.folder_list || []);
        }
        await this.renderFavoritesFromStore();
        failed = false;
      }

      let watchPrefix = this.watchPrefix();
      let watchResp = await this.apiService.getWatchList(1);
      if (watchResp.code === 200 && watchResp.data) {
        let items: RespJmAlbumInfo[] = watchResp.data.list;
        await AlbumDao.clearFeedPrefix(watchPrefix);
        await AlbumDao.saveFeedKeepList(`${watchPrefix}1`, items, -1);
        this.watchCurrentPage = 1;
        this.watchHasMore = items.length > 0;
        await this.renderWatchFromStore();
        failed = false;
      }
      if (failed) {
        this.getUIContext().getPromptAction().showToast({ message: '刷新失败，已保留本地内容', duration: 2000 });
      }
    } catch (err) {
      console.error('[ProfilePage] pull refresh error:', JSON.stringify(err));
      this.getUIContext().getPromptAction().showToast({ message: '刷新失败，已保留本地内容', duration: 2000 });
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
    }
  }

  async loadWatchHistory(): Promise<void> {
    if (this.watchIsLoading) return;
    // 一进函数就置加载态：读库这几毫秒也别让用户看到空历史
    this.watchIsLoading = true;
    this.watchLoadFailed = false;
    let prefix = this.watchPrefix();
    let page = this.watchCurrentPage;
    // 1. 本地优先
    if (page === 1) {
      let hasLocal = await this.renderWatchFromStore();
      if (hasLocal && !this.isWatchStale()) {
        let pages = await AlbumDao.feedPageNumbers(prefix);
        this.watchCurrentPage = pages.length > 0 ? pages[pages.length - 1] : 1;
        this.watchIsLoading = false;
        return;
      }
      if (hasLocal) {
        // 过期：历史整体作废，从第一页重拉
        await AlbumDao.clearFeedPrefix(prefix);
        this.watchAlbums = [];
        this.watchCurrentPage = 1;
        page = 1;
      }
    } else {
      let cached = await AlbumDao.loadFeed(`${prefix}${page}`);
      if (cached.sections.length > 0 && cached.sections[0].albums.length > 0) {
        await this.renderWatchFromStore();
        this.watchHasMore = cached.sections[0].albums.length > 0;
        this.watchIsLoading = false;
        return;
      }
    }
    // 2. 本地缺失才走网络
    try {
      let resp = await this.apiService.getWatchList(page);
      if (resp.code === 200 && resp.data) {
        let items = resp.data.list;
        // 3. 先落库，再从库读回来渲染
        await AlbumDao.saveFeed(`${prefix}${page}`, items, -1);
        await this.renderWatchFromStore();
        // 无新数据时停止加载
        this.watchHasMore = items.length > 0;
      }
    } catch (err) {
      console.error('[ProfilePage] loadWatchHistory error:', JSON.stringify(err));
      this.watchLoadFailed = true;
    } finally {
      this.watchIsLoading = false;
      // 本地计算历史总数
      this.watchTotal = this.watchAlbums.length;
    }
  }

  loadMoreWatch(): void {
    if (this.watchIsLoading || !this.watchHasMore) return;
    this.watchCurrentPage++;
    this.loadWatchHistory();
  }

  // ─── 历史管理态（长按多选删除） ───

  /** 长按进入历史管理态，并自动选中长按项 */
  enterWatchSelectMode(albumId: number): void {
    if (this.watchSelectMode) return;
    this.watchSelectMode = true;
    this.watchSelectedIds = new Set<string>([String(albumId)]);
  }

  /** 退出管理态：清选中 */
  exitWatchSelectMode(): void {
    if (!this.watchSelectMode) return;
    this.watchSelectMode = false;
    this.watchSelectedIds = new Set<string>();
  }

  /** 管理态下点卡片：切换选中（重新赋值 Set 确保触发刷新） */
  toggleWatchSelected(albumId: number): void {
    let key = String(albumId);
    let next = new Set<string>(this.watchSelectedIds);
    if (next.has(key)) {
      next.delete(key);
    } else {
      next.add(key);
    }
    this.watchSelectedIds = next;
  }

  /** 管理态胶囊层：全屏包装（Transparent 不拦空白区点击），胶囊悬浮于 HdsTabs 上方居中 */
  @Builder
  watchGripCapsuleLayer() {
    Stack() {
      Row() {
        this.watchCapsuleButton($r('sys.symbol.trash'), '删除', '#FF5A5F',
          (): void => { this.onWatchDeleteClick(); })
        Divider()
          .vertical(true)
          .strokeWidth(0.5)
          .height(30)
          .color($r('sys.color.comp_divider'))
        this.watchCapsuleButton($r('sys.symbol.xmark'), '取消', $r('app.color.text_primary'),
          (): void => { this.exitWatchSelectMode(); })
      }
      .padding({ left: 6, right: 6, top: 8, bottom: 8 })
      .borderRadius(34)
      .backgroundBlurStyle(BlurStyle.Thin)
      .backgroundColor('#33000000')
      // 删除请求进行中禁用整颗胶囊，防并发第二轮删除/中途退出
      .enabled(!this.isDeleting)
      .opacity(this.isDeleting ? 0.5 : 1)
      // 吸收胶囊缝隙（分隔线/内边距）点击，防穿透误触下层列表
      .onClick(() => {})
      // 「光在胶囊内」：顶缘白光泽渐隐 + 发丝描边，静态属性
      .linearGradient({
        angle: 180,
        colors: [['#1FFFFFFF', 0], ['#00FFFFFF', 0.4]]
      })
      .border({ width: 0.5, color: '#1AFFFFFF' })
      // 居中（Stack Bottom 对齐默认水平居中），上抬 HdsTabs 悬浮栏总占用 + 8vp 间隔
      .offset({ y: -92 })
      // 出现/退出转场：淡入并自底部上滑
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: 60 }))
        .animation({ duration: 250, curve: Curve.EaseInOut }))
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  watchCapsuleButton(icon: Resource, label: string, color: ResourceColor, action: () => void) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([color])
      Text(label)
        .fontSize(11)
        .fontColor(color)
        .margin({ top: 2 })
    }
    .width(60)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .onClick(() => action())
  }

  /** 确认弹窗（统一走 UIContext 形态）：返回是否点击了确认键 */
  private async confirmDialog(title: string, message: string, confirmText: string): Promise<boolean> {
    try {
      let result = await this.getUIContext().getPromptAction().showDialog({
        title: title,
        message: message,
        buttons: [
          { text: '取消', color: '#999999' },
          { text: confirmText, color: '#FF5A5F' }
        ]
      });
      return result.index === 1;
    } catch (err) {
      console.warn('[ProfilePage] dialog dismissed:', JSON.stringify(err));
      return false;
    }
  }

  /** 胶囊删除钮：确认后逐条调删除接口；部分失败时保留管理态与剩余选中 */
  async onWatchDeleteClick(): Promise<void> {
    if (this.isDeleting) return;
    if (this.watchSelectedIds.size === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请先选择要删除的记录', duration: 2000 });
      return;
    }
    let count = this.watchSelectedIds.size;
    let ok = await this.confirmDialog('删除观看记录', `确定删除选中的 ${count} 条观看记录吗？删除后不可恢复。`, '删除');
    if (!ok) return;

    // 快照待删集合：循环/过滤全程基于快照，不读实时选中态（防循环中被取消导致失真）
    let targets: string[] = Array.from(this.watchSelectedIds);
    this.isDeleting = true;
    let failed = new Set<string>();
    for (let id of targets) {
      try {
        await this.apiService.deleteWatchRecord(id);
      } catch (err) {
        console.error('[ProfilePage] deleteWatchRecord error:', JSON.stringify(err));
        failed.add(id);
      }
    }
    this.isDeleting = false;

    // 从列表移除删除成功的项，删除失败的保留（判断基于 targets 快照）
    this.watchAlbums = this.watchAlbums.filter((a: AlbumViewModel) => {
      let key = String(a.id);
      return targets.indexOf(key) === -1 || failed.has(key);
    });
    this.watchTotal = this.watchAlbums.length;

    // 服务端已变更：作废本地历史分页，下次读取重新联网拉取
    await AlbumDao.clearFeedPrefix(this.watchPrefix());
    this.watchCurrentPage = 1;

    if (failed.size === 0) {
      this.getUIContext().getPromptAction().showToast({ message: `已删除 ${count} 条观看记录`, duration: 2000 });
      this.exitWatchSelectMode();
    } else {
      this.getUIContext().getPromptAction().showToast({
        message: `${count - failed.size} 条已删除，${failed.size} 条删除失败`,
        duration: 2000
      });
      // 仅保留失败项的选中态，可重试
      this.watchSelectedIds = new Set<string>(failed);
    }
  }

  buildAvatarUrl(): string {
    let photo = this.apiService.getUserSession().photo;
    if (!photo) return '';
    let domain = this.apiService.getImageDomain();
    return `https://${domain}/media/users/${photo}`;
  }

  onAlbumClick(album: AlbumViewModel): void {
    navPush('AlbumDetailPage', { albumId: album.id, albumName: album.name } as AlbumDetailParams);
  }

  build() {
    Refresh({ refreshing: $$this.isRefreshing }) {
    Scroll(this.outerScroller) {
      Column() {
        if (this.isLoggedIn) {
          // ── 已登录状态 ──

          // 账号信息栏（紧凑）：头像居左，昵称/等级纵向排列并与头像居中对齐，右缘箭头；整行点击进入账号管理
          Row() {
            if (this.buildAvatarUrl()) {
              Image(this.buildAvatarUrl())
                .width(52)
                .height(52)
                .borderRadius(26)
                .objectFit(ImageFit.Cover)
                .backgroundColor($r('app.color.bg_secondary'))
            } else {
              Image($r('app.media.ic_default_avatar'))
                .width(52)
                .height(52)
                .borderRadius(26)
                .objectFit(ImageFit.Cover)
                .backgroundColor($r('app.color.bg_secondary'))
            }

            Column() {
              Text(this.apiService.getUserSession().username)
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text(`Lv.${this.apiService.getUserSession().level} · ${this.apiService.getUserSession().levelName}`)
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 3 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 12 })
            .layoutWeight(1)

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor([$r('app.color.text_disabled')])
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ top: 16 })
          .onClick(() => this.onOpenAccountManage())

          // ── 下载管理入口 ──
          this.DownloadEntryCard()

          // ── 设置入口 ──
          this.SettingsEntryCard()

          // ── 收藏/历史列表 ──
          Tabs({ controller: this.tabsController, barPosition: BarPosition.Start }) {
            // 收藏 Tab
            TabContent() {
              List() {
                ListItem() {
                  Column() {
                    // 收藏夹标签
                    if (this.favFolders.length > 0) {
                      Scroll() {
                        Row() {
                          Text('全部')
                            .fontSize(13)
                            .fontColor(this.favCurrentFolderId === '0' ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
                            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                            .backgroundColor(this.favCurrentFolderId === '0' ? $r('app.color.brand') : $r('app.color.bg_page'))
                            .borderRadius(14)
                            .margin({ right: 8 })
                            .onClick(() => this.onFolderChange('0'))

                          ForEach(this.favFolders, (folder: FavoriteFolderItem) => {
                            Text(folder.name)
                              .fontSize(13)
                              .fontColor(this.favCurrentFolderId === folder.FID ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
                              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                              .backgroundColor(this.favCurrentFolderId === folder.FID ? $r('app.color.brand') : $r('app.color.bg_page'))
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

                    // 收藏列表
                    if (this.favAlbums.length === 0 && this.favIsLoading) {
                      Column() {
                        LoadingProgress().width(40).height(40).color($r('app.color.brand'))
                        Text('加载中...').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 12 })
                      }
                      .width('100%')
                      .height(300)
                      .justifyContent(FlexAlign.Center)
                    } else if (this.favAlbums.length === 0 && this.favLoadFailed) {
                      Column() {
                        Text('加载失败').fontSize(16).fontColor($r('app.color.text_tertiary'))
                        Button('重新加载')
                          .fontSize(14)
                          .fontColor($r('app.color.text_on_accent'))
                          .backgroundColor($r('app.color.brand'))
                          .borderRadius(18)
                          .padding({ left: 24, right: 24 })
                          .height(36)
                          .margin({ top: 16 })
                          .onClick(() => this.loadFavorites())
                      }
                      .width('100%')
                      .height(200)
                      .justifyContent(FlexAlign.Center)
                    } else if (this.favAlbums.length === 0) {
                      Column() {
                        Text('暂无收藏').fontSize(16).fontColor($r('app.color.text_tertiary'))
                      }
                      .width('100%')
                      .height(200)
                      .justifyContent(FlexAlign.Center)
                    } else {
                      Grid() {
                        ForEach(this.favAlbums, (album: AlbumViewModel) => {
                          GridItem() {
                            this.FavAlbumCard(album, false, false)
                          }
                          .onClick(() => this.onAlbumClick(album))
                        }, (album: AlbumViewModel) => `${album.id}`)
                      }
                      .columnsTemplate(this.isTablet ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
                      .columnsGap(10)
                      .rowsGap(10)
                      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                    }

                    // 收藏加载更多（自动加载）
                    if (this.favIsLoading && this.favAlbums.length > 0) {
                      Row() {
                        LoadingProgress().width(20).height(20).color($r('app.color.brand'))
                        Text('加载中...').fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ left: 6 })
                      }
                      .width('100%').justifyContent(FlexAlign.Center)
                      .padding({ top: 12, bottom: 20 })
                    }
                    if (this.favLoadFailed && this.favAlbums.length > 0) {
                      Row() {
                        Text('加载失败').fontSize(12).fontColor($r('app.color.text_tertiary'))
                        Text('重新加载').fontSize(12).fontColor($r('app.color.brand')).margin({ left: 12 })
                      }
                      .width('100%').justifyContent(FlexAlign.Center)
                      .padding({ top: 12, bottom: 20 })
                      .onClick(() => this.loadFavorites())
                    }
                    if (!this.favHasMore && this.favAlbums.length > 0) {
                      Text('没有更多了').fontSize(12).fontColor($r('app.color.text_disabled'))
                        .width('100%').textAlign(TextAlign.Center)
                        .padding({ top: 8, bottom: 20 })
                    }
                  }
                  .width('100%')
                  .padding({ bottom: this.bottomSafeHeight + 100 })
                }
              }
              .width('100%')
              .nestedScroll({
                scrollForward: NestedScrollMode.PARENT_FIRST,
                scrollBackward: NestedScrollMode.SELF_FIRST
              })
              .onReachEnd(() => {
                if (this.favHasMore && !this.favIsLoading) {
                  this.favCurrentPage++;
                  this.loadFavorites();
                }
              })
            }
            .tabBar('收藏')

            // 历史 Tab
            TabContent() {
              Stack() {
                List() {
                ListItem() {
                  Column() {
                    // 历史列表
                    if (this.watchAlbums.length === 0 && this.watchIsLoading) {
                      Column() {
                        LoadingProgress().width(40).height(40).color($r('app.color.brand'))
                        Text('加载中...').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 12 })
                      }
                      .width('100%')
                      .height(300)
                      .justifyContent(FlexAlign.Center)
                    } else if (this.watchAlbums.length === 0 && this.watchLoadFailed) {
                      Column() {
                        Text('加载失败').fontSize(16).fontColor($r('app.color.text_tertiary'))
                        Button('重新加载')
                          .fontSize(14)
                          .fontColor($r('app.color.text_on_accent'))
                          .backgroundColor($r('app.color.brand'))
                          .borderRadius(18)
                          .padding({ left: 24, right: 24 })
                          .height(36)
                          .margin({ top: 16 })
                          .onClick(() => this.loadWatchHistory())
                      }
                      .width('100%')
                      .height(200)
                      .justifyContent(FlexAlign.Center)
                    } else if (this.watchAlbums.length === 0) {
                      Column() {
                        Text('暂无观看记录').fontSize(16).fontColor($r('app.color.text_tertiary'))
                      }
                      .width('100%')
                      .height(200)
                      .justifyContent(FlexAlign.Center)
                    } else {
                      Grid() {
                        ForEach(this.watchAlbums, (album: AlbumViewModel) => {
                          GridItem() {
                            this.FavAlbumCard(album, this.watchSelectMode, this.watchSelectedIds.has(String(album.id)))
                          }
                          .onClick(() => {
                            // 管理态下整个卡片区域（含复选框）都是选择热区；常态下进详情
                            if (this.watchSelectMode) {
                              this.toggleWatchSelected(album.id);
                            } else {
                              this.onAlbumClick(album);
                            }
                          })
                          .gesture(LongPressGesture({ repeat: false, duration: 500 })
                            .onAction(() => this.enterWatchSelectMode(album.id)))
                        }, (album: AlbumViewModel) =>
                          // 管理态/选中态编入键值：@Builder 按值传参不随 @State 刷新，
                          // 靠键值变化触发 GridItem 重建（下载管理页同款解法）
                          `${album.id}|${this.watchSelectMode ? 1 : 0}|${this.watchSelectedIds.has(String(album.id)) ? 1 : 0}`)
                      }
                      .columnsTemplate(this.isTablet ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
                      .columnsGap(10)
                      .rowsGap(10)
                      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                    }

                    // 历史加载更多（自动加载）
                    if (this.watchIsLoading && this.watchAlbums.length > 0) {
                      Row() {
                        LoadingProgress().width(20).height(20).color($r('app.color.brand'))
                        Text('加载中...').fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ left: 6 })
                      }
                      .width('100%').justifyContent(FlexAlign.Center)
                      .padding({ top: 12, bottom: 20 })
                    }
                    if (this.watchLoadFailed && this.watchAlbums.length > 0) {
                      Row() {
                        Text('加载失败').fontSize(12).fontColor($r('app.color.text_tertiary'))
                        Text('重新加载').fontSize(12).fontColor($r('app.color.brand')).margin({ left: 12 })
                      }
                      .width('100%').justifyContent(FlexAlign.Center)
                      .padding({ top: 12, bottom: 20 })
                      .onClick(() => this.loadWatchHistory())
                    }
                    if (!this.watchHasMore && this.watchAlbums.length > 0) {
                      Text('没有更多了').fontSize(12).fontColor($r('app.color.text_disabled'))
                        .width('100%').textAlign(TextAlign.Center)
                        .padding({ top: 8, bottom: 20 })
                    }
                  }
                  .width('100%')
                  .padding({ bottom: this.bottomSafeHeight + 100 })
                }
              }
              .width('100%')
              .height('100%')
              .nestedScroll({
                scrollForward: NestedScrollMode.PARENT_FIRST,
                scrollBackward: NestedScrollMode.SELF_FIRST
              })
              .onReachEnd(() => {
                if (this.watchHasMore && !this.watchIsLoading) {
                  this.loadMoreWatch();
                }
              })

                // 管理态胶囊层：条件渲染保证退出管理态时热区一并移除；
                // 包装层 Transparent 不拦截空白区点击，落到下层列表
                if (this.watchSelectMode) {
                  this.watchGripCapsuleLayer()
                }
              }
              .width('100%')
              .height('100%')
              .alignContent(Alignment.Bottom)
              // 个人中心被切走/滚出视口即退出管理态（覆盖外层 HdsTabs 切换场景）
              .onVisibleAreaChange([0.0, 0.1], (isVisible: boolean) => {
                if (!isVisible) {
                  this.exitWatchSelectMode();
                }
              })
            }
            .tabBar('历史')
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
          .onChange(() => {
            // 离开历史 Tab 时退出管理态（胶囊随 TabContent 隐藏收尾）
            this.exitWatchSelectMode();
          })
        } else {
          // ── 未登录状态 ──

          Row() {
            SymbolGlyph($r('sys.symbol.person'))
              .fontSize(48)
              .fontColor([$r('app.color.text_disabled')])

            Column() {
              Text('未登录')
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('点击登录以同步收藏')
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 14 })
            .layoutWeight(1)

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(20)
              .fontColor([$r('app.color.text_disabled')])
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 24, bottom: 20 })
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ top: 16 })
          .onClick(() => this.onLogin())

          // ── 下载管理入口 ──
          this.DownloadEntryCard()

          // ── 设置入口 ──
          this.SettingsEntryCard()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 64 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor($r('app.color.bg_page'))
    }
    .onRefreshing(() => {
      this.pullRefresh();
    })
    .width('100%')
    .height('100%')
  }

  /** 下载管理入口卡片：与设置入口同款式，置于设置上方（下载功能无需登录） */
  @Builder
  DownloadEntryCard() {
    Row() {
      SymbolGlyph($r('sys.symbol.download'))
        .fontSize(20)
        .fontColor([$r('app.color.text_secondary')])

      Text('下载管理')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 10 })
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([$r('app.color.text_disabled')])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ top: 12 })
    .onClick(() => this.onOpenDownloads())
  }

  /** 设置入口卡片：黑白模式、清理缓存等设置项已统一迁入设置页 */
  @Builder
  SettingsEntryCard() {
    Row() {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(20)
        .fontColor([$r('app.color.text_secondary')])

      Text('设置')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 10 })
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([$r('app.color.text_disabled')])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ top: 12 })
    .onClick(() => this.onOpenSettings())
  }

  /**
   * 收藏/历史共用卡片。
   * 历史管理态下 inSelectMode=true：选中时整封面叠半透明黑遮罩 + 居中白勾
   * （视觉与下载管理页选择态同款），左上角复选框标识管理态与选中状态；
   * 收藏 Tab 固定传 (false, false)，不进管理态。
   */
  @Builder
  FavAlbumCard(album: AlbumViewModel, inSelectMode: boolean, selected: boolean) {
    Column() {
      // 封面容器定尺寸（与封面同比例）：遮罩层的百分比才有确定基准，否则会撑爆 Stack
      Stack({ alignContent: Alignment.TopStart }) {
        Image(album.coverUrl)
          .width('100%')
          .aspectRatio(0.72)
          .objectFit(ImageFit.Cover)
          .borderRadius({ topLeft: 8, topRight: 8 })
          .backgroundColor($r('app.color.bg_secondary'))

        if (inSelectMode && selected) {
          // 选中态：整封面遮罩 + 居中白勾（下载管理页同款）
          Column() {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontSize(26)
              .fontColor([$r('app.color.text_on_accent')])
          }
          .width('100%')
          .height('100%')
          .borderRadius({ topLeft: 8, topRight: 8 })
          .backgroundColor('#8C000000')
          .justifyContent(FlexAlign.Center)
        }

        if (inSelectMode) {
          Row() {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(12)
              .fontColor([$r('app.color.text_on_accent')])
              .opacity(selected ? 1 : 0)
          }
          .width(22)
          .height(22)
          .justifyContent(FlexAlign.Center)
          .borderRadius(11)
          .backgroundColor(selected ? $r('app.color.brand') : '#80000000')
          .border({ width: 1.5, color: selected ? $r('app.color.brand') : '#E6FFFFFF' })
          .margin({ left: 6, top: 6 })
        }
      }
      .aspectRatio(0.72)
      .constraintSize({ maxWidth: this.isTablet ? 200 : 180 })

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
    .border({ width: 2, color: selected ? $r('app.color.brand') : Color.Transparent })
    .shadow({
      radius: 4,
      color: $r('app.color.scrim'),
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
  // 初值 true：首次安装库为空时，读库这几毫秒也要有加载指示而不是空白
  @State isLoading: boolean = true;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State currentCategory: string = CATEGORY_ALL;
  @State currentOrder: string = ORDER_BY_LATEST;
  @State searchKeyword: string = '';
  @State loadFailed: boolean = false;
  /** 下拉刷新指示器：用户显式拉取，与首屏 isLoading 分开 */
  @State isRefreshing: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  /** 设置页改了刷新间隔 / 切回分类页时递增，按新的 TTL 重新判断 */
  @StorageProp('feedRefreshTick') @Watch('onFeedRefreshTick') feedRefreshTick: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private cache: CacheManager | null = null;
  /** 本地列表最近一次落库时间，用来判断是否过期 */
  private localUpdatedAt: number = 0;
  /** 当前分类+排序在库里的分页前缀：cat:{分类}:{排序}:p */
  private pagePrefix: string = '';
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;
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
    this.rebuildPagePrefix();
    await this.loadFirstPage();
  }

  private rebuildPagePrefix(): void {
    this.pagePrefix = `cat:${this.currentCategory}:${this.currentOrder}:p`;
  }

  /** 首屏：先读库回放，本地缺失或过期才联网 */
  private async loadFirstPage(): Promise<void> {
    this.loadFailed = false;
    let hasLocal = await this.renderFromStore();
    if (hasLocal && !this.isStale()) {
      this.isLoading = false;
      let pages = await AlbumDao.feedPageNumbers(this.pagePrefix);
      this.currentPage = pages.length > 0 ? pages[pages.length - 1] : 1;
      return;
    }
    if (hasLocal) {
      // 过期：整列表作废回第一页重拉，避免新旧分页拼在一起
      this.isLoading = true;
      await AlbumDao.clearFeedPrefix(this.pagePrefix);
      this.albums = [];
    }
    this.currentPage = 1;
    await this.loadAlbums();
  }

  /** 本地列表是否过期（间隔与开关都由设置页控制） */
  private isStale(): boolean {
    return Date.now() - this.localUpdatedAt > CacheManager.feedTtlMsOf(CacheManager.REFRESH_CATEGORY);
  }

  onFeedRefreshTick(): void {
    if (this.isLoading) return;
    this.loadFirstPage();
  }

  /** 从库里读出全部分页并渲染 */
  private async renderFromStore(): Promise<boolean> {
    let snapshots = await AlbumDao.loadFeedPages(this.pagePrefix);
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

  async loadAlbums(): Promise<void> {
    // 是否在加载由调用方（loadMore / tryAutoLoad）判断：这里不能再挡，
    // 否则首屏进网络分支时 isLoading 已是 true，会被自己拦死
    let page = this.currentPage;
    let pageKey = `${this.pagePrefix}${page}`;
    // 1. 本地已有这一页：直接用
    let cached = await AlbumDao.loadFeed(pageKey);
    if (cached.sections.length > 0 && cached.sections[0].albums.length > 0) {
      await this.renderFromStore();
      this.hasMore = cached.sections[0].albums.length >= 20;
      this.isLoading = false;
      return;
    }
    // 2. 本地缺失才走网络
    this.isLoading = true;
    this.loadFailed = false;
    try {
      let resp = await this.apiService.getCategoryList(
        this.currentCategory,
        this.currentOrder,
        page
      );

      console.info(`[CategoryPage] getCategoryList resp: code=${resp.code}, data type=${typeof resp.data}`);
      if (resp.code === 200 && resp.data) {
        let data = resp.data as SearchResultData;
        console.info(`[CategoryPage] data.total=${data.total}, content length=${data.content?.length}`);
        // 3. 先落库，再从库读回来渲染
        await AlbumDao.saveFeed(pageKey, data.content, parseInt(data.total) || 0);
        if (this.cache) {
          this.cache.saveLastCategory(this.currentCategory);
          this.cache.saveLastOrder(this.currentOrder);
        }
        await this.renderFromStore();
        this.hasMore = data.content.length >= 20;
      } else {
        console.error(`[CategoryPage] getCategoryList failed: code=${resp.code}, message=${resp.message}`);
        this.loadFailed = true;
      }
    } catch (err) {
      console.error('loadAlbums error:', JSON.stringify(err));
      this.loadFailed = true;
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
    this.isLoading = true;
    this.rebuildPagePrefix();
    await this.loadFirstPage();
  }

  async onOrderChange(order: string): Promise<void> {
    if (this.currentOrder === order) return;
    this.currentOrder = order;
    this.currentPage = 1;
    this.hasMore = true;
    this.albums = [];
    this.isLoading = true;
    this.rebuildPagePrefix();
    await this.loadFirstPage();
  }

  loadMore(): void {
    if (!this.hasMore || this.isLoading) return;
    this.currentPage++;
    this.loadAlbums();
  }

  /**
   * 下拉刷新：当前分类 / 排序从第一页重拉。
   * 不走 TTL、不看自动刷新开关，这是用户的显式动作。
   * 与首页同款：旧内容留在屏上，落库后再由 renderFromStore 整体替换，
   * 中间不置 isLoading、不清 albums，避免拉取期间整页闪成加载态。
   */
  private async pullRefresh(): Promise<void> {
    if (this.isPulling) {
      this.isRefreshing = false;
      return;
    }
    this.isPulling = true;
    try {
      let resp = await this.apiService.getCategoryList(this.currentCategory, this.currentOrder, 1);
      let data = resp.code === 200 && resp.data ? resp.data as SearchResultData : null;
      if (data === null) {
        this.getUIContext().getPromptAction().showToast({ message: '刷新失败，已保留本地内容', duration: 2000 });
        return;
      }
      // 旧分页不再对应这份列表，整批作废后只写新的第一页
      await AlbumDao.clearFeedPrefix(this.pagePrefix);
      await AlbumDao.saveFeedKeepList(`${this.pagePrefix}1`, data.content, parseInt(data.total) || 0);
      this.currentPage = 1;
      this.hasMore = data.content.length >= 20;
      await this.renderFromStore();
    } catch (err) {
      console.error('[CategoryPage] pull refresh error:', JSON.stringify(err));
      this.getUIContext().getPromptAction().showToast({ message: '刷新失败，已保留本地内容', duration: 2000 });
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
    }
  }

  buildAvatarUrl(): string {
    let photo = this.apiService.getUserSession().photo;
    if (!photo) return '';
    let domain = this.apiService.getImageDomain();
    return `https://${domain}/media/users/${photo}`;
  }

  onAlbumClick(album: AlbumViewModel): void {
    navPush('AlbumDetailPage', { albumId: album.id, albumName: album.name } as AlbumDetailParams);
  }

  // 注：原 onSearch/onLogin/onFavorites 为无调用的死代码（onFavorites 指向不存在的
  // pages/FavoritePage），随 router 迁移一并删除。

  onMoreCategory(): void {
    navPush('SearchPage');
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
          Scroll() {
            Column() {
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

              // 加载更多失败时给出重试入口
              if (this.loadFailed) {
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
                .height(48)
                .justifyContent(FlexAlign.Center)
                .onClick(() => this.loadAlbums())
              } else if (this.isLoading) {
                Row() {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color($r('app.color.brand'))
                  Text('加载中...')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .height(48)
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('100%')
            // 内容尾部留白：视口撑满全屏（延伸到悬浮 TabBar/导航条背后），由内容垫高避让
            .padding({ bottom: this.bottomSafeHeight + 100 })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .padding({ top: this.topSafeHeight + 172 })
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

      // ── 浮层：排序 + 分类标签（毛玻璃） ──
      Column() {
        // ── 排序选择器 ──
        Row() {
          ForEach(this.orders, (item: OrderItem) => {
            Text(item.label)
              .fontSize(13)
              .fontColor(this.currentOrder === item.key ? $r('app.color.brand') : $r('app.color.text_secondary'))
              .fontWeight(this.currentOrder === item.key ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.currentOrder === item.key ? $r('app.color.brand_bg') : $r('app.color.bg_page'))
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
                .fontColor(this.currentCategory === cat ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor(this.currentCategory === cat ? $r('app.color.brand') : $r('app.color.bg_page'))
                .borderRadius(16)
                .margin({ right: 8 })
                .onClick(() => this.onCategoryChange(cat))
            })

            // 查看更多
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor([$r('app.color.text_secondary')])
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor($r('app.color.bg_page'))
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
      .backgroundColor($r('app.color.overlay_bg'))
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
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
  @State loadFailed: boolean = false;
  /** 下拉刷新指示器：用户显式拉取，与首屏 isLoading 分开 */
  @State isRefreshing: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  /** 设置页改了刷新间隔 / 切回讨论区时递增，按新的 TTL 重新判断 */
  @StorageProp('feedRefreshTick') @Watch('onFeedRefreshTick') feedRefreshTick: number = 0;
  private apiService: ApiService = ApiService.getInstance();

  private modes: ForumModeItem[] = [
    { key: COMMENT_MODE_ALL, label: COMMENT_MODE_NAME_MAP[COMMENT_MODE_ALL] } as ForumModeItem,
    { key: COMMENT_MODE_MANHUA, label: COMMENT_MODE_NAME_MAP[COMMENT_MODE_MANHUA] } as ForumModeItem,
    { key: COMMENT_MODE_CHAT, label: COMMENT_MODE_NAME_MAP[COMMENT_MODE_CHAT] } as ForumModeItem,
  ];

  private cache: CacheManager | null = null;
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    await this.loadComments();
  }

  onFeedRefreshTick(): void {
    if (this.isLoading || this.isLoadingMore) return;
    this.loadComments();
  }

  /** 论坛评论按模式分别缓存，ownerId 固定为 forum */
  private renderFromStore(): boolean {
    if (!this.cache) return false;
    let comments: CommentInfo[] = [];
    let total = 0;
    for (let page of this.cache.getCommentPages(this.currentMode, 'forum')) {
      let entry = this.cache.loadCommentPage(this.currentMode, 'forum', page);
      if (entry === null) continue;
      total = Math.max(total, entry.total);
      let raws = JSON.parse(entry.data) as CommentInfoRaw[];
      for (let raw of raws) {
        comments.push(parseCommentRaw(raw));
      }
    }
    this.comments = comments;
    if (total > 0) {
      this.totalComments = total;
    }
    this.hasMore = this.comments.length < this.totalComments;
    return comments.length > 0;
  }

  async loadComments(): Promise<void> {
    this.loadFailed = false;
    // 1. 本地优先
    if (this.renderFromStore()) {
      this.isLoading = false;
      return;
    }
    // 2. 本地缺失才走网络
    this.isLoading = true;
    try {
      let page = this.currentPage;
      let data: CommentPageData = await this.apiService.getComments(this.currentMode, '', page);
      // 3. 先落库，再从库读回来渲染
      if (this.cache) {
        this.cache.saveCommentPage(this.currentMode, 'forum', page, JSON.stringify(data.list || []), data.total);
      }
      if (!this.renderFromStore()) {
        this.totalComments = data.total;
        this.comments = (data.list || []).map((raw) => parseCommentRaw(raw));
        this.hasMore = this.comments.length < this.totalComments;
      }
    } catch (err) {
      console.error('[ForumPage] loadComments error:', JSON.stringify(err));
      this.loadFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  async loadMoreComments(): Promise<void> {
    if (!this.hasMore || this.isLoadingMore) return;
    this.loadFailed = false;
    let page = this.currentPage + 1;
    // 1. 本地已有这一页：直接用
    if (this.cache && this.cache.loadCommentPage(this.currentMode, 'forum', page) !== null) {
      this.currentPage = page;
      this.renderFromStore();
      return;
    }
    // 2. 本地缺失才走网络
    this.isLoadingMore = true;
    try {
      let data: CommentPageData = await this.apiService.getComments(this.currentMode, '', page);
      if (this.cache) {
        this.cache.saveCommentPage(this.currentMode, 'forum', page, JSON.stringify(data.list || []), data.total);
      }
      this.currentPage = page;
      if (!this.renderFromStore()) {
        this.comments = this.comments.concat((data.list || []).map((raw) => parseCommentRaw(raw)));
        this.hasMore = this.comments.length < this.totalComments;
      }
    } catch (err) {
      console.error('[ForumPage] loadMoreComments error:', JSON.stringify(err));
      this.loadFailed = true;
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

  /**
   * 下拉刷新：当前模式的评论从第一页重拉。
   * 不走 TTL，也不清 this.comments：旧内容留在屏上，落库后由 renderFromStore 整体替换。
   * 旧分页整批作废，否则新第 1 页会和旧分页拼出重复条目（ForEach 用 comment.id 做 key）。
   */
  private async pullRefresh(): Promise<void> {
    if (this.isPulling) {
      this.isRefreshing = false;
      return;
    }
    this.isPulling = true;
    try {
      let data: CommentPageData = await this.apiService.getComments(this.currentMode, '', 1);
      this.cache?.clearCommentPages(this.currentMode, 'forum');
      if (this.cache) {
        this.cache.saveCommentPage(this.currentMode, 'forum', 1, JSON.stringify(data.list || []), data.total);
      }
      this.currentPage = 1;
      if (!this.renderFromStore()) {
        this.totalComments = data.total;
        this.comments = (data.list || []).map((raw) => parseCommentRaw(raw));
        this.hasMore = this.comments.length < this.totalComments;
      }
    } catch (err) {
      console.error('[ForumPage] pull refresh error:', JSON.stringify(err));
      this.getUIContext().getPromptAction().showToast({ message: '刷新失败，已保留本地内容', duration: 2000 });
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
    }
  }

  build() {
    Column() {
      // ── 模式筛选栏 ──
      Row() {
        ForEach(this.modes, (item: ForumModeItem) => {
          Text(item.label)
            .fontSize(13)
            .fontColor(this.currentMode === item.key ? $r('app.color.brand') : $r('app.color.text_secondary'))
            .fontWeight(this.currentMode === item.key ? FontWeight.Bold : FontWeight.Normal)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor(this.currentMode === item.key ? $r('app.color.brand_bg') : $r('app.color.bg_page'))
            .borderRadius(14)
            .margin({ right: 8 })
            .onClick(() => this.onModeChange(item.key))
        })

        Blank()

        Text(`${this.totalComments} 条`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_card'))

      // ── 评论列表 ──
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
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.comments.length === 0 && this.loadFailed) {
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
            .onClick(() => this.loadComments())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.comments.length === 0) {
        Column() {
          Text('暂无评论')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
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
              .onClick(() => this.loadMoreComments())
            } else if (this.hasMore) {
              Text('上拉加载更多')
                .fontSize(13)
                .fontColor($r('app.color.text_disabled'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 16 })
            } else {
              Text('没有更多了')
                .fontSize(13)
                .fontColor($r('app.color.text_disabled'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 16 })
            }
          }
          // 内容尾部留白：视口撑满全屏（延伸到悬浮 TabBar/导航条背后），由内容垫高避让
          .padding({ bottom: this.bottomSafeHeight + 100 })
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
        .onRefreshing(() => {
          this.pullRefresh();
        })
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topSafeHeight + 64 })
    .backgroundColor($r('app.color.bg_page'))
  }

  async handleSendReply(commentId: string, albumId: string, text: string): Promise<void> {
    if (!this.apiService.isLoggedIn()) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '请先登录后再回复', duration: 2000 });
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
  @State showRouteSheet: boolean = false;
  @State apiDomains: string[] = [];
  @State imageDomains: string[] = [];
  @State selectedApiIndex: number = -1;
  @State selectedImageIndex: number = -1;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  // Navigation 根容器导航栈：唯一实例，经 AppStorage 供全部页面/组件使用（NavHelper）
  private pathStack: NavPathStack = new NavPathStack();
  private controller: HdsTabsController = new HdsTabsController();
  private apiService: ApiService = ApiService.getInstance();
  // 顶部图标钮沉浸光感材质：API 26 uiMaterial.ImmersiveMaterial + 光感交互反馈；
  // 模拟器/低版本/不支持设备回退纯色底（compatibleSdk 23，见 NOTICE 待办）
  private lightMaterial: uiMaterial.ImmersiveMaterial | undefined = this.createLightMaterial();

  private createLightMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (DeviceUtils.isEmulator()) {
      return undefined;
    }
    try {
      // 低版本运行时无此模块/接口，typeof 探测 + try/catch 双保险
      if (typeof uiMaterial.isImmersiveMaterialSupported === 'function' && !uiMaterial.isImmersiveMaterialSupported()) {
        return undefined;
      }
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        lightEffect: { color: Color.White }
      });
    } catch (e) {
      console.warn('[Index] immersive material unsupported:', JSON.stringify(e));
      return undefined;
    }
  }

  async aboutToAppear(): Promise<void> {
    // 注册全局导航栈（须早于任何子组件的跳转调用）
    AppStorage.setOrCreate('navPathStack', this.pathStack);
    // 冷启动恢复登录态，分两步：
    // 1) 用本地会话快照先点亮界面——首页/个人中心一进来就是已登录，不等网络
    // 2) 后台静默登录复验；失败则退回未登录态（快照与内存会话一起清）
    let accountManager = AccountManager.getInstance();
    try {
      await accountManager.init();
    } catch (err) {
      console.warn('[Index] account init failed:', JSON.stringify(err));
    }
    // 用户关掉「自动登录」时，快照与凭据都不参与启动，直接停在未登录
    let autoLogin = accountManager.isAutoLoginEnabled();
    let snapshot = autoLogin ? accountManager.loadSessionSnapshot() : null;
    let creds = autoLogin ? accountManager.getActiveCredentials() : null;
    // 必须先置 pending 再点亮登录态：isLoggedIn 的 @Watch 是同步触发的，
    // 晚一步个人中心就会拿着未复验的会话去拉收藏
    if (creds !== null) {
      AppStorage.setOrCreate('sessionPending', true);
    }
    if (snapshot !== null) {
      this.apiService.adoptSession(snapshot);
    }
    if (creds !== null) {
      // 不 await：复验走后台，慢网络也不拖住首屏
      this.silentLogin(accountManager, creds);
    } else if (snapshot !== null) {
      // 有快照却没留密码（未勾选「记住密码」），无法复验，直接回到未登录
      accountManager.clearSessionSnapshot();
      this.apiService.logout();
    }
    // 后台按用户设置清理图片仓库中的过期章节（不阻塞首屏）
    this.autoCleanupLibrary();
  }

  /**
   * 后台静默登录：用保存的凭据重新登录，成功刷新会话与快照，失败退回未登录。
   *
   * 复验期间置 sessionPending，个人中心等页面据此暂缓发起需要登录的请求，
   * 避免拿尚未验证的会话打空枪。
   */
  private async silentLogin(accountManager: AccountManager, creds: ActiveCredentials): Promise<void> {
    AppStorage.setOrCreate('sessionPending', true);
    try {
      console.info('[Index] 静默登录开始, username=' + creds.username);
      let session = await this.apiService.login(creds.username, creds.password);
      // 回填头像/等级等信息到账号条目，同时刷新会话快照
      await accountManager.recordLogin(creds.username, creds.password, session, true);
      console.info('[Index] 静默登录成功');
    } catch (err) {
      console.warn('[Index] 静默登录失败，回到未登录态:', JSON.stringify(err));
      let msg = (err as Error).message || '';
      let networkIssue = msg.includes('网络') || msg.includes('超时');
      // 网络问题不代表凭据失效：快照留着，联网恢复后下次启动仍能直接亮起
      if (!networkIssue) {
        accountManager.clearSessionSnapshot();
      }
      this.apiService.logout();
      let hint = networkIssue ? '网络异常，已切换为未登录' : '登录已失效，请重新登录';
      try {
        this.getUIContext().getPromptAction().showToast({ message: hint, duration: 2000 });
      } catch (e) {
        console.error('[Index] showToast error:', JSON.stringify(e));
      }
    } finally {
      AppStorage.setOrCreate('sessionPending', false);
    }
  }

  /** 冷启动后台清理：阅读缓存按设置天数、已导出内容按设置天数，手动下载未导出内容不动 */
  private async autoCleanupLibrary(): Promise<void> {
    try {
      let cache = await CacheManager.getInstance();
      let readDays = cache.getReadCacheDays();
      let exportedDays = cache.getExportedDays();
      if (readDays === 0 && exportedDays === 0) {
        return;
      }
      let lib = await ComicLibrary.getInstance();
      let rule: CleanupRule = {
        readCacheDays: readDays,
        exportedDays: exportedDays,
      } as CleanupRule;
      let result = await lib.cleanup(rule);
      if (result.removedChapters > 0) {
        console.info(`[Index] auto cleanup removed ${result.removedChapters} chapters`);
      }
    } catch (err) {
      console.warn('[Index] auto cleanup error:', JSON.stringify(err));
    }
  }

  onSearch(): void {
    navPush('SearchPage');
  }

  onToggleRoute(): void {
    let dm = this.apiService.getDomainManager();
    this.apiDomains = dm.getApiDomains();
    this.imageDomains = dm.getImageDomains();
    this.selectedApiIndex = dm.getSelectedApiIndex();
    this.selectedImageIndex = dm.getSelectedImageIndex();
    this.showRouteSheet = true;
  }

  onApiRouteSelect(index: number): void {
    this.apiService.getDomainManager().setApiIndex(index);
    this.selectedApiIndex = index;
  }

  onImageRouteSelect(index: number): void {
    this.apiService.getDomainManager().setImageIndex(index);
    this.selectedImageIndex = index;
  }

  /** 线路选择半模态（bindSheet 标准件）：双组(API/图片)×(自动+N线路)+URL 副文本 */
  @Builder
  RouteSheetBuilder() {
    Column() {
      Text('选择 API / 图片线路')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: 4 })

      Row({ space: 16 }) {
        Column() {
          Text('API')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ bottom: 4 })
          // 自动线路：index 约定 -1
          this.RouteOption(0, -1, '自动', '', (): void => {
            this.onApiRouteSelect(-1);
            this.showRouteSheet = false;
          })
          ForEach(this.apiDomains, (route: string, index: number) => {
            this.RouteOption(0, index, '线路' + (index + 1).toString(), route, (): void => {
              this.onApiRouteSelect(index);
              this.showRouteSheet = false;
            })
          }, (route: string) => route)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('图片')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ bottom: 4 })
          this.RouteOption(1, -1, '自动', '', (): void => {
            this.onImageRouteSelect(-1);
            this.showRouteSheet = false;
          })
          ForEach(this.imageDomains, (route: string, index: number) => {
            this.RouteOption(1, index, '线路' + (index + 1).toString(), route, (): void => {
              this.onImageRouteSelect(index);
              this.showRouteSheet = false;
            })
          }, (route: string) => route)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: this.bottomSafeHeight + 16 })
  }

  /**
   * 单条线路选项行：整行 40vp 点击带 + 选中态 + URL 副文本。
   * 选中态在 builder 体内直读状态（踩坑记录 §95：参数求值阶段读状态＝零刷新依赖）；
   * 自动线路 index 约定 -1。
   */
  @Builder
  RouteOption(group: number, index: number, label: string, url: string, onSelect: () => void) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight((group === 0 ? this.selectedApiIndex : this.selectedImageIndex) === index
          ? FontWeight.Bold : FontWeight.Normal)
        .fontColor((group === 0 ? this.selectedApiIndex : this.selectedImageIndex) === index
          ? $r('app.color.brand') : $r('app.color.text_primary'))
      if ((group === 0 ? this.selectedApiIndex : this.selectedImageIndex) === index) {
        Text(' ✓')
          .fontSize(14)
          .fontColor($r('app.color.brand'))
      }
      Blank()
      if (url !== '') {
        Text(url)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .constraintSize({ maxWidth: 140 })
      }
    }
    .width('100%')
    .height(40)
    .onClick(onSelect)
  }

  @Builder TabBarBuilder(icon: Resource, label: string, index: number) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.currentIndex === index ? $r('app.color.tab_active') : $r('app.color.tab_inactive')])
      Text(label)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? $r('app.color.tab_active') : $r('app.color.tab_inactive'))
    }
    .padding({ top: 8, bottom: 4 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Navigation(this.pathStack) {
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
          // 固定 28vp：HdsTabs 悬浮栏自身已含导航条避让，barBottomMargin 不叠加 bottomSafeHeight
          //（叠加会双重抬高，真机实测约定 2026-11-19）
          barBottomMargin: 28,
          // 底部渐变半透明遮罩（HdsTabs 自带 gradientMask）：不配置时默认高度仅 TabBar 高+32vp 偏矮，
          // 显式加高到 140；maskColor 复用主题雾色 overlay_bg（浅色白雾/深色深灰），自动跟随深浅色
          gradientMask: {
            maskColor: $r('app.color.overlay_bg'),
            maskHeight: 140
          },
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
          // 切页时让常驻列表页按 TTL 重判一次；未过期列表内部会直接返回，不发请求
          let tick: number = AppStorage.get<number>('feedRefreshTick') ?? 0;
          AppStorage.setOrCreate('feedRefreshTick', tick + 1);
        })
      } else {
        // Fallback for unsupported SystemCapability
      }

      // ── 沉浸式顶部栏（浮层 + 毛玻璃） ──
      Row() {
        Text('JMComic')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Button({ type: ButtonType.Normal }) {
          Text('防失联')
            .fontSize(13)
            .fontColor($r('app.color.brand'))
        }
        .backgroundColor($r('app.color.brand_bg'))
        .borderRadius(14)
        .height(32)
        .padding({ left: 10, right: 10 })
        .margin({ left: 8 })
        .onClick(() => navPush('AboutPage'))

        Blank()

        // 线路：40vp 光感圆形图标钮（纯 symbol，无文字）
        Stack() {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(22)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(this.lightMaterial ? Color.Transparent : $r('app.color.bg_page'))
        .systemMaterial(this.lightMaterial)
        .margin({ right: 8 })
        .onClick(() => this.onToggleRoute())
        .bindSheet(this.showRouteSheet!!, this.RouteSheetBuilder(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: false,
          showClose: true,
          preferType: SheetType.BOTTOM
        })

        // 搜索：40vp 光感圆形图标钮（纯 symbol，无文字）
        Stack() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(22)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(this.lightMaterial ? Color.Transparent : $r('app.color.bg_page'))
        .systemMaterial(this.lightMaterial)
        .onClick(() => this.onSearch())
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 16, bottom: 4 })
      .backgroundColor($r('app.color.header_bg'))
      .backdropBlur(20)
      .zIndex(10)

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
  }
}
