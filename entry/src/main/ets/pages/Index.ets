import { display, uiMaterial } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import { AlbumViewModel, JmPromoteSection, SearchResultData, IAlbumViewModelJSON,
  CommentInfo, CommentPageData, parseCommentRaw,
  COMMENT_MODE_ALL, COMMENT_MODE_MANHUA, COMMENT_MODE_CHAT, COMMENT_MODE_NAME_MAP,
  FavoriteAlbumItem, FavoriteFolderItem,
  RespJmAlbumInfo,
  respToJmAlbumInfo,
} from '../models/Album';
import { CacheManager } from '../common/CacheManager';
import {
  CATEGORY_ALL, CATEGORY_DOUJIN, CATEGORY_SINGLE, CATEGORY_SHORT,
  CATEGORY_ANOTHER, CATEGORY_HANMAN, CATEGORY_MEIMAN,
  CATEGORY_DOUJIN_COSPLAY, CATEGORY_3D, CATEGORY_ENGLISH_SITE,
  CATEGORY_NAME_MAP, ORDER_BY_LATEST, ORDER_MONTH_RANKING,
  ORDER_WEEK_RANKING, ORDER_DAY_RANKING, ORDER_BY_LIKE,
  ORDER_NAME_MAP, PAGE_SIZE_FAVORITE,
  SECTION_SOURCE_LATEST, SECTION_SOURCE_PROMOTE,
} from '../common/Constants';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { CommentItemComponent } from '../common/CommentItem';
import { DeviceUtils } from 'common';
import { AccountManager } from '../common/AccountManager';
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
@Component
struct HomePage {
  @State sections: JmPromoteSection[] = [];
  @State latestAlbums: RespJmAlbumInfo[] = [];
  @State isLoading: boolean = true;
  @State loadFailed: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  async aboutToAppear(): Promise<void> {
    await this.loadData();
  }

  /** 加载首页数据；失败时可由「重新加载」按钮再次调用 */
  async loadData(): Promise<void> {
    this.isLoading = true;
    this.loadFailed = false;
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
        this.latestAlbums = latestResp.data as RespJmAlbumInfo[];
      }
    } catch (err) {
      console.error('[HomePage] load error:', JSON.stringify(err));
      this.loadFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  onSectionMore(title: string, albums: RespJmAlbumInfo[], source: string): void {
    navPush('SectionMorePage', { sectionTitle: title, initialAlbums: albums, source: source } as SectionMoreParams);
  }

  @Builder
  SectionMoreEntry(title: string, albums: RespJmAlbumInfo[], source: string) {
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
    .onClick(() => this.onSectionMore(title, albums, source))
  }

  build() {
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

                this.SectionMoreEntry('最新上传', this.latestAlbums, SECTION_SOURCE_LATEST)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16, bottom: 10 })

              Scroll() {
                Row({ space: 10 }) {
                  ForEach(this.latestAlbums, (album: RespJmAlbumInfo) => {
                    JmAlbumCard({ isTablet: this.isTablet, cardInfo: respToJmAlbumInfo(album) })
                  }, (album: RespJmAlbumInfo) => {
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
          ForEach(this.sections, (section: JmPromoteSection) => {
            Column() {
              // 分区标题
              Row() {
                Text(section.title)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)

                // 传入当前推广分区自身的标题与数据，不能用「最新上传」，
                // 否则所有分区的更多页都会展示最新上传数据并走错分页接口
                this.SectionMoreEntry(section.title, section.content, SECTION_SOURCE_PROMOTE)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16, bottom: 10 })

              // 横向滑动列表
              Scroll() {
                Row({ space: 10 }) {
                  ForEach(section.content, (album: RespJmAlbumInfo) => {
                    JmAlbumCard({isTablet: this.isTablet, cardInfo: respToJmAlbumInfo(album)})
                  }, (album: RespJmAlbumInfo) => {
                    return `${album.id}`
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
      .padding({ top: this.topSafeHeight + 64, bottom: this.bottomSafeHeight + 100 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor($r('app.color.bg_page'))
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
  @StorageProp('activeUsername') @Watch('onActiveUserChanged') activeUsername: string = '';
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
  private tabsController: TabsController = new TabsController();
  private outerScroller: Scroller = new Scroller();
  private apiService: ApiService = ApiService.getInstance();
  private loadedUsername: string = '';
  private isTablet: boolean = (display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels) >= 600;

  aboutToAppear(): void {
    AppStorage.setOrCreate('isLoggedIn', this.apiService.isLoggedIn());
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

  /** 同一账号仅加载一次；账号变更时重置列表并重新加载 */
  private ensureLoadedForUser(): void {
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

  async loadFavorites(): Promise<void> {
    if (this.favIsLoading) return;
    this.favIsLoading = true;
    this.favLoadFailed = false;
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
        // 去重合并：避免 ForEach key 重复
        let map = new Map<number, AlbumViewModel>();
        for (let vm of this.favAlbums) { map.set(vm.id, vm); }
        for (let vm of vms) { map.set(vm.id, vm); }
        this.favAlbums = Array.from(map.values());
        this.favHasMore = vms.length >= PAGE_SIZE_FAVORITE;
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

  async loadWatchHistory(): Promise<void> {
    if (this.watchIsLoading) return;
    this.watchIsLoading = true;
    this.watchLoadFailed = false;
    try {
      let resp = await this.apiService.getWatchList(this.watchCurrentPage);
      if (resp.code === 200 && resp.data) {
        let vms = resp.data.list.map((item: RespJmAlbumInfo) => {
          let vm = AlbumViewModel.fromApiInfo(item, '');
          vm.coverUrl = this.apiService.buildCoverUrl(vm.id);
          return vm;
        });
        // 去重合并：历史记录同一漫画可能出现在多页
        let map = new Map<number, AlbumViewModel>();
        for (let vm of this.watchAlbums) { map.set(vm.id, vm); }
        let newCount = 0;
        for (let vm of vms) {
          if (!map.has(vm.id)) {
            map.set(vm.id, vm);
            newCount++;
          }
        }
        this.watchAlbums = Array.from(map.values());
        // 无新数据时停止加载
        this.watchHasMore = newCount > 0;
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
  @State isLoading: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State currentCategory: string = CATEGORY_ALL;
  @State currentOrder: string = ORDER_BY_LATEST;
  @State searchKeyword: string = '';
  @State loadFailed: boolean = false;
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
    this.loadFailed = false;

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
    this.loadFailed = false;
    try {
      let data: CommentPageData = await this.apiService.getComments(this.currentMode, '', this.currentPage);
      this.totalComments = data.total;
      this.comments = (data.list || []).map((raw) => parseCommentRaw(raw));
      this.hasMore = this.comments.length < this.totalComments;
    } catch (err) {
      console.error('[ForumPage] loadComments error:', JSON.stringify(err));
      this.loadFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  async loadMoreComments(): Promise<void> {
    if (!this.hasMore || this.isLoadingMore) return;
    this.isLoadingMore = true;
    this.loadFailed = false;
    this.currentPage++;
    try {
      let data: CommentPageData = await this.apiService.getComments(this.currentMode, '', this.currentPage);
      let newComments = (data.list || []).map((raw) => parseCommentRaw(raw));
      this.comments = this.comments.concat(newComments);
      this.hasMore = this.comments.length < this.totalComments;
    } catch (err) {
      console.error('[ForumPage] loadMoreComments error:', JSON.stringify(err));
      this.currentPage--;
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
    // 自动登录：多账号管理器取活跃账号的凭据
    try {
      let accountManager = AccountManager.getInstance();
      await accountManager.init();
      let creds = accountManager.getActiveCredentials();
      if (creds) {
        console.info('[Index] 尝试自动登录, username=' + creds.username);
        let session = await this.apiService.login(creds.username, creds.password);
        // 回填头像/等级等信息到账号条目
        await accountManager.recordLogin(creds.username, creds.password, session, true);
        console.info('[Index] 自动登录成功');
      }
    } catch (err) {
      console.warn('[Index] 自动登录失败:', JSON.stringify(err));
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
