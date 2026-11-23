import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ThemeSetting } from '../common/ThemeSetting';
import { CacheManager } from '../common/CacheManager';
import { ComicLibrary } from '../common/ComicLibrary';
import { navPop } from '../common/NavHelper';
import { AppDatabase } from '../storage/AppDatabase';

/**
 * 设置页面
 *
 * 按用户操作对象分组：
 * - 显示：黑白模式
 * - 内容刷新：刷新间隔、刷新范围（哪些页面参与）、刷新内容（字段/封面/章节图片重建哪一层）
 * - 漫画图片：仓库占用、保留策略（含「导出后立即删除」）、强制清空
 * - 存储清理：临时缓存（cacheDir，含原始图快照，不碰已解码图片）
 * - 阅读：阅读页码清除（最后阅读章节与已读标记保留）
 */
@Component
struct SettingsPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  /** 缓存目录体积文案（异步计算后回填） */
  @State cacheText: string = '计算中…';
  /** 图片仓库保留策略（0 表示不自动清理） */
  @State readCacheDays: number = 7;
  /** 已导出内容保留：-1 表示导出后立即删除，0 表示不自动清理 */
  @State exportedDays: number = 0;
  /** 刷新间隔（分钟，0 表示不自动刷新） */
  @State feedRefreshMinutes: number = CacheManager.DEFAULT_FEED_TTL_MINUTES;
  /** 各类内容是否参与自动刷新（关掉后该类只用本地） */
  @State autoRefreshHome: boolean = true;
  @State autoRefreshCategory: boolean = true;
  @State autoRefreshSearch: boolean = true;
  @State autoRefreshDetail: boolean = true;
  @State autoRefreshProfile: boolean = true;
  @State autoRefreshForum: boolean = true;
  /** 刷新内容维度：刷新时是否重建漫画字段 / 封面 / 章节图片 */
  @State contentField: boolean = true;
  @State contentCover: boolean = true;
  @State contentImage: boolean = true;
  /** 统一图片仓库体积（异步计算后回填） */
  @State librarySizeText: string = '计算中…';
  /** 供并排分段按钮使用；0 表示不自动清理 */
  private readonly readCacheOptions: number[] = [0, 3, 7, 30];
  /** 已导出保留的哨兵值：-1 表示打包成功后立即删除（不是天数） */
  private readonly exportedDeleteNow: number = -1;
  private readonly exportedOptions: number[] = [0, 7, 30, -1];
  /** 列表刷新间隔预设（分钟，界面上按小时展示）；0 表示不自动刷新 */
  private readonly refreshOptions: number[] = [60, 120, 360, 720, 1440, 0];
  private cache: CacheManager | null = null;
  /** 自定义分钟数弹窗（输入框每次打开重新挂载，因此 controller 可复用） */
  private refreshDialog: CustomDialogController = new CustomDialogController({
    builder: RefreshMinutesDialog({
      onConfirm: (minutes: number) => this.setFeedRefreshMinutes(minutes)
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
    width: '82%'
  });

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    this.readCacheDays = this.cache.getReadCacheDays();
    // 立即删除存在独立布尔开关里，展示时映射成保留策略的哨兵值
    this.exportedDays = this.cache.isAutoDeleteAfterExport()
      ? this.exportedDeleteNow : this.cache.getExportedDays();
    this.feedRefreshMinutes = this.cache.getFeedRefreshMinutes();
    this.autoRefreshHome = CacheManager.isAutoRefresh(CacheManager.REFRESH_HOME);
    this.autoRefreshCategory = CacheManager.isAutoRefresh(CacheManager.REFRESH_CATEGORY);
    this.autoRefreshSearch = CacheManager.isAutoRefresh(CacheManager.REFRESH_SEARCH);
    this.autoRefreshDetail = CacheManager.isAutoRefresh(CacheManager.REFRESH_DETAIL);
    this.autoRefreshProfile = CacheManager.isAutoRefresh(CacheManager.REFRESH_PROFILE);
    this.autoRefreshForum = CacheManager.isAutoRefresh(CacheManager.REFRESH_FORUM);
    this.contentField = CacheManager.isAutoRefresh(CacheManager.CONTENT_FIELD);
    this.contentCover = CacheManager.isAutoRefresh(CacheManager.CONTENT_COVER);
    this.contentImage = CacheManager.isAutoRefresh(CacheManager.CONTENT_IMAGE);
    this.refreshCacheSize();
    this.refreshLibrarySize();
  }

  onBack(): void {
    navPop();
  }

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: 4, top: 10, bottom: 4 })
  }

  /**
   * 一类内容的自动刷新开关（整行可点；Toggle 只做状态展示）。
   * 行内不缓存 isOn，统一走 isAutoRefreshOn(kind)，这样 @Builder 也能依赖到对应 @State。
   */
  @Builder
  RefreshToggleRow(title: string, desc: string, kind: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(desc)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.isAutoRefreshOn(kind) })
        .selectedColor($r('app.color.brand'))
        .margin({ left: 12 })
        // Toggle 会吞掉点击、不冒泡到整行 onClick（模拟器实测），禁其自身命中，由整行单通道切换
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => this.setAutoRefresh(kind, !this.isAutoRefreshOn(kind)))
  }

  // ─── 显示 ───

  // ─── 漫画图片 ───

  /** 阅读缓存保留：按钮直接选中指定天数 */
  private setReadCacheDays(days: number): void {
    if (this.readCacheDays === days) return;
    this.readCacheDays = days;
    this.cache?.saveReadCacheDays(days);
  }

  /**
   * 已导出保留：按钮直接选中；哨兵值表示打包成功后立即删除，其余按天数清理。
   * 选项本身就是说明，切换时不再弹提示。
   */
  private setExportedDays(days: number): void {
    if (this.exportedDays === days) return;
    this.exportedDays = days;
    let deleteNow = days === this.exportedDeleteNow;
    // 导出流程读的是布尔开关；按天清理的 pref 只存天数，不写哨兵值
    this.cache?.setAutoDeleteAfterExport(deleteNow);
    this.cache?.saveExportedDays(deleteNow ? 0 : days);
  }

  /** 刷新间隔：选中即保存；写时间戳让已创建的常驻页按新间隔重判 */
  private setFeedRefreshMinutes(minutes: number): void {
    if (this.feedRefreshMinutes === minutes) return;
    this.feedRefreshMinutes = minutes;
    this.cache?.saveFeedRefreshMinutes(minutes);
    this.bumpRefreshTick();
  }

  /** 读当前开关值（@Builder 里按 kind 取，保证依赖到对应的 @State） */
  private isAutoRefreshOn(kind: string): boolean {
    if (kind === CacheManager.REFRESH_HOME) return this.autoRefreshHome;
    if (kind === CacheManager.REFRESH_CATEGORY) return this.autoRefreshCategory;
    if (kind === CacheManager.REFRESH_SEARCH) return this.autoRefreshSearch;
    if (kind === CacheManager.REFRESH_DETAIL) return this.autoRefreshDetail;
    if (kind === CacheManager.REFRESH_PROFILE) return this.autoRefreshProfile;
    if (kind === CacheManager.REFRESH_FORUM) return this.autoRefreshForum;
    if (kind === CacheManager.CONTENT_FIELD) return this.contentField;
    if (kind === CacheManager.CONTENT_COVER) return this.contentCover;
    return this.contentImage;
  }

  /** 切换某类内容的自动刷新；关闭后该类只用本地，不因超时而联网 */
  private setAutoRefresh(kind: string, enabled: boolean): void {
    if (enabled === this.isAutoRefreshOn(kind)) return;
    if (kind === CacheManager.REFRESH_HOME) {
      this.autoRefreshHome = enabled;
    } else if (kind === CacheManager.REFRESH_CATEGORY) {
      this.autoRefreshCategory = enabled;
    } else if (kind === CacheManager.REFRESH_SEARCH) {
      this.autoRefreshSearch = enabled;
    } else if (kind === CacheManager.REFRESH_DETAIL) {
      this.autoRefreshDetail = enabled;
    } else if (kind === CacheManager.REFRESH_PROFILE) {
      this.autoRefreshProfile = enabled;
    } else if (kind === CacheManager.REFRESH_FORUM) {
      this.autoRefreshForum = enabled;
    } else if (kind === CacheManager.CONTENT_FIELD) {
      this.contentField = enabled;
    } else if (kind === CacheManager.CONTENT_COVER) {
      this.contentCover = enabled;
    } else {
      this.contentImage = enabled;
    }
    this.cache?.saveAutoRefresh(kind, enabled);
    // 开关变化等价于「TTL 规则变了」：让常驻页立即按新规则重判一次
    this.bumpRefreshTick();
    this.getUIContext().getPromptAction().showToast({
      message: this.toggleToast(kind, enabled),
      duration: 1500
    });
  }

  /** 两组开关的提示语：范围组说「刷不刷」，内容组说「重建哪一层」 */
  private toggleToast(kind: string, enabled: boolean): string {
    if (kind === CacheManager.CONTENT_FIELD) {
      return enabled ? '已开启：刷新时更新漫画字段' : '已关闭：已有漫画信息保持本地内容';
    }
    if (kind === CacheManager.CONTENT_COVER) {
      return enabled ? '已开启：封面换图随刷新更新' : '已关闭：封面一直用本地旧图';
    }
    if (kind === CacheManager.CONTENT_IMAGE) {
      return enabled ? '已开启：章节图片变化时重新下载' : '已关闭：章节图片不再重新下载';
    }
    return enabled ? '已开启：超过间隔后自动刷新' : '已关闭：该类内容只用本地缓存';
  }

  /** 首页/分类/论坛/个人中心常驻，不会重新 aboutToAppear，靠这个时间戳重判 TTL */
  private bumpRefreshTick(): void {
    let tick: number = AppStorage.get<number>('feedRefreshTick') ?? 0;
    AppStorage.setOrCreate('feedRefreshTick', tick + 1);
  }

  /** 当前值是否不在预设里（决定「自定义」是否高亮） */
  private isCustomRefresh(): boolean {
    return this.refreshOptions.indexOf(this.feedRefreshMinutes) < 0;
  }

  private refreshText(minutes: number): string {
    if (minutes <= 0) {
      return '不自动';
    }
    return minutes % 60 === 0 ? `${minutes / 60} 小时` : `${minutes} 分钟`;
  }

  private async refreshLibrarySize(): Promise<void> {
    try {
      let lib = await ComicLibrary.getInstance();
      this.librarySizeText = this.formatSize(await lib.totalSize());
    } catch (e) {
      console.warn('[SettingsPage] calc library size error:', JSON.stringify(e));
      this.librarySizeText = '--';
    }
  }

  /** 手动强制清空整个图片仓库（不受保留时长限制）；阅读位置等记录不受影响 */
  private async onClearLibrary(): Promise<void> {
    let ok = await this.confirmDialog('清空图片仓库',
      '将删除全部已缓存/已下载的漫画图片，包括手动下载的内容；下次阅读或下载需重新获取。阅读位置记录不受影响。',
      '清空');
    if (!ok) return;
    try {
      let lib = await ComicLibrary.getInstance();
      let result = await lib.clearAll();
      await this.refreshLibrarySize();
      // cacheDir 下的原始图快照也随仓库一起清掉了，缓存体积文案同步刷新
      await this.refreshCacheSize();
      this.getUIContext().getPromptAction().showToast({
        message: `已清空 ${result.removedChapters} 个章节`,
        duration: 2000
      });
    } catch (e) {
      console.error('[SettingsPage] clear library error:', JSON.stringify(e));
      this.getUIContext().getPromptAction().showToast({ message: '清空失败', duration: 2000 });
    }
  }

  // ─── 存储清理 ───

  /** 清理缓存：仅清临时目录（cacheDir），已解码的漫画图片不受影响 */
  async onClearCache(): Promise<void> {
    let ok = await this.confirmDialog('清理缓存',
      '将清理应用临时文件（含服务器原始图快照、导出压缩临时包），不会删除已解码的漫画图片与下载记录。',
      '清理');
    if (!ok) return;
    try {
      let context = getContext() as common.UIAbilityContext;
      let freed = await this.clearDirChildren(context.cacheDir);
      // cacheDir 已清空：album 上的统计/评论游标列同步置空（用户态与已下载状态不动）
      await AppDatabase.clearAlbumCache();
      this.getUIContext().getPromptAction().showToast({
        message: `已清理 ${this.formatSize(freed)}`,
        duration: 2000
      });
      await this.refreshCacheSize();
    } catch (e) {
      console.error('[SettingsPage] clear cache error:', JSON.stringify(e));
      this.getUIContext().getPromptAction().showToast({ message: '清理失败', duration: 2000 });
    }
  }

  // ─── 阅读 ───

  /** 清除全部漫画的阅读页码；最后阅读章节与已读标记保留 */
  private async onClearReadPositions(): Promise<void> {
    let ok = await this.confirmDialog('清除阅读位置',
      '将清除所有漫画的上次阅读页码；最后阅读的章节与已读标记保留。下次打开漫画会进入上次那一章，从第 1 页开始。',
      '清除');
    if (!ok) return;
    try {
      if (!this.cache) {
        this.cache = await CacheManager.getInstance();
      }
      let removed = this.cache.clearAllReadPositions();
      this.getUIContext().getPromptAction().showToast({
        message: removed > 0 ? `已清除 ${removed} 本漫画的阅读页码` : '没有阅读页码记录',
        duration: 2000
      });
    } catch (e) {
      console.error('[SettingsPage] clear read positions error:', JSON.stringify(e));
      this.getUIContext().getPromptAction().showToast({ message: '清除失败', duration: 2000 });
    }
  }

  // ─── 通用工具 ───

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
      console.warn('[SettingsPage] dialog dismissed:', JSON.stringify(err));
      return false;
    }
  }

  /** 异步统计目录体积（fileIo 异步 IO，不阻塞渲染） */
  private async calcDirSize(dirPath: string): Promise<number> {
    let total = 0;
    if (!fileIo.accessSync(dirPath)) {
      return 0;
    }
    let names = await fileIo.listFile(dirPath);
    for (let name of names) {
      let fullPath = `${dirPath}/${name}`;
      let stat = await fileIo.stat(fullPath);
      if (stat.isDirectory()) {
        total += await this.calcDirSize(fullPath);
      } else {
        total += stat.size;
      }
    }
    return total;
  }

  /** 清空目录内容（保留目录本身），返回释放的字节数；子目录交给 fileIo.rmdir 递归删除 */
  private async clearDirChildren(dirPath: string): Promise<number> {
    let freed = 0;
    if (!fileIo.accessSync(dirPath)) {
      return 0;
    }
    let names = await fileIo.listFile(dirPath);
    for (let name of names) {
      let fullPath = `${dirPath}/${name}`;
      let stat = await fileIo.stat(fullPath);
      if (stat.isDirectory()) {
        freed += await this.calcDirSize(fullPath);
        await fileIo.rmdir(fullPath);
      } else {
        freed += stat.size;
        await fileIo.unlink(fullPath);
      }
    }
    return freed;
  }

  /** 异步重算并回填缓存体积文案 */
  private async refreshCacheSize(): Promise<void> {
    try {
      let context = getContext() as common.UIAbilityContext;
      this.cacheText = this.formatSize(await this.calcDirSize(context.cacheDir));
    } catch (e) {
      console.warn('[SettingsPage] calc cache size error:', JSON.stringify(e));
      this.cacheText = '--';
    }
  }

  private formatSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  private daysText(days: number): string {
    if (days === this.exportedDeleteNow) return '立即删除';
    return days === 0 ? '不自动清理' : `${days} 天`;
  }

  build() {
    NavDestination() {
      Column() {
        // ── 顶部栏 ──
        Row() {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(22)
              .fontColor([$r('app.color.text_primary')])
          }
          .backgroundColor(Color.Transparent)
          .width(36)
          .height(36)
          .onClick(() => this.onBack())

          Text('设置')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .margin({ right: 36 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topSafeHeight + 6, bottom: 6 })
        .backgroundColor($r('app.color.bg_card'))

        // ── 内容区：按操作对象分组 ──
        Scroll() {
          Column() {
            // ══ 显示 ══
            this.SectionTitle('显示')
            ThemeSetting()

            // ══ 内容刷新 ══
            this.SectionTitle('内容刷新')
            Column() {
              Column() {
                Text('刷新间隔')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text('本地数据超过该时长后自动联网刷新；选「不自动」则全部只用本地')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 4 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.refreshOptions, (minutes: number) => {
                    Text(this.refreshText(minutes))
                      .fontSize(12)
                      .fontColor(this.feedRefreshMinutes === minutes
                        ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .borderRadius(14)
                      .backgroundColor(this.feedRefreshMinutes === minutes
                        ? $r('app.color.brand') : $r('app.color.bg_secondary'))
                      .margin({ right: 8, top: 8 })
                      .onClick(() => this.setFeedRefreshMinutes(minutes))
                  }, (minutes: number) => `refresh_${minutes}`)

                  // 不在预设里的值也算自定义，选中态跟着当前值走
                  Text(this.isCustomRefresh() ? `自定义 ${this.refreshText(this.feedRefreshMinutes)}` : '自定义')
                    .fontSize(12)
                    .fontColor(this.isCustomRefresh()
                      ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .backgroundColor(this.isCustomRefresh()
                      ? $r('app.color.brand') : $r('app.color.bg_secondary'))
                    .margin({ right: 8, top: 8 })
                    .onClick(() => this.refreshDialog.open())
                }
                .width('100%')
                .margin({ top: 4 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              // 各类内容是否参与自动刷新：关掉后该类只用本地，不受上面的间隔影响
              Column() {
                Text('自动刷新范围')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text('关闭后该类内容只用本地，不会因超过间隔而联网')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 4 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 14, bottom: 2 })

              this.RefreshToggleRow('首页推荐', '推荐轮播与最新更新，含各分区的「更多」',
                CacheManager.REFRESH_HOME)
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              this.RefreshToggleRow('分类浏览', '按分类 / 排序浏览的漫画列表',
                CacheManager.REFRESH_CATEGORY)
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              this.RefreshToggleRow('搜索列表', '同一关键词的搜索结果快照',
                CacheManager.REFRESH_SEARCH)
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              this.RefreshToggleRow('漫画详情', '章节列表与作品信息',
                CacheManager.REFRESH_DETAIL)
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              this.RefreshToggleRow('收藏与历史', '我的收藏、观看历史',
                CacheManager.REFRESH_PROFILE)
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              this.RefreshToggleRow('讨论区', '论坛与作品评论',
                CacheManager.REFRESH_FORUM)

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              // 刷新内容：联网拿到数据后，决定哪一层产物跟着重建
              Column() {
                Text('刷新内容')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text('只作用于自动刷新：联网后重建哪些本地数据；关闭的维度一直沿用旧值')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 4 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 14, bottom: 2 })

              this.RefreshToggleRow('漫画字段', '标题、作者、简介、统计与章节目录',
                CacheManager.CONTENT_FIELD)
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              this.RefreshToggleRow('封面', '服务器换了封面图就重下并替换本地旧图',
                CacheManager.CONTENT_COVER)
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              this.RefreshToggleRow('章节图片', '作品换图时重新下载页图；会消耗额外流量',
                CacheManager.CONTENT_IMAGE)

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              // 手动下拉与本组开关无关：它只换列表成员，不重建已有作品
              Text('下拉刷新不受上面这些开关约束：它只替换列表成员与顺序来拉取新漫画，已有作品的字段与封面一律不动')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ top: 8 })

            // ══ 漫画图片（阅读/下载/导出共用的统一仓库）══
            this.SectionTitle('漫画图片')
            Column() {
              // 占用 + 强制清空
              Row() {
                Column() {
                  Text('图片仓库占用')
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                  Text('阅读 / 下载 / 导出共用这一份图片')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text(this.librarySizeText)
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ right: 12 })

                Text('清空')
                  .fontSize(13)
                  .fontColor('#FF5A5F')
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => this.onClearLibrary())

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              // 阅读缓存保留（分段按钮）
              Column() {
                Text('阅读缓存保留')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text('仅阅读、未手动下载的章节图片')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 4 })

                Row({ space: 8 }) {
                  ForEach(this.readCacheOptions, (days: number) => {
                    Text(this.daysText(days))
                      .fontSize(12)
                      .fontColor(this.readCacheDays === days
                        ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .borderRadius(14)
                      .backgroundColor(this.readCacheDays === days
                        ? $r('app.color.brand') : $r('app.color.bg_secondary'))
                      .onClick(() => this.setReadCacheDays(days))
                  }, (days: number) => `read_${days}`)
                }
                .margin({ top: 10 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              // 已导出内容保留（分段按钮）
              Column() {
                Text('已导出内容保留')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text('已导出压缩包的章节图片；选「立即删除」则打包成功后马上清理，仅保留下载记录')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 4 })

                Row({ space: 8 }) {
                  ForEach(this.exportedOptions, (days: number) => {
                    Text(this.daysText(days))
                      .fontSize(12)
                      .fontColor(this.exportedDays === days
                        ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .borderRadius(14)
                      .backgroundColor(this.exportedDays === days
                        ? $r('app.color.brand') : $r('app.color.bg_secondary'))
                      .onClick(() => this.setExportedDays(days))
                  }, (days: number) => `exported_${days}`)
                }
                .margin({ top: 10 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ top: 8 })

            // ══ 存储清理 ══
            this.SectionTitle('存储清理')
            Column() {
              Row() {
                Column() {
                  Text('清理缓存')
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                  Text('含原始图快照与导出临时包，不影响已解码的漫画图片')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text(this.cacheText)
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => this.onClearCache())
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ top: 8 })

            // ══ 阅读 ══
            this.SectionTitle('阅读')
            Column() {
              Row() {
                Column() {
                  Text('阅读位置')
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                  Text('清除所有漫画的上次阅读页码，最后阅读章节与已读标记保留')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('清除')
                  .fontSize(13)
                  .fontColor('#FF5A5F')
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => this.onClearReadPositions())
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ top: 8 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .onShown(() => {
      this.refreshCacheSize();
      this.refreshLibrarySize();
    })
  }
}

/**
 * 自定义列表刷新间隔（分钟）
 * 只负责输入与校验，落库与生效由 SettingsPage.setFeedRefreshMinutes 完成
 */
@CustomDialog
struct RefreshMinutesDialog {
  controller?: CustomDialogController;
  onConfirm: (minutes: number) => void = () => {
  };
  @State input: string = '';

  aboutToAppear(): void {
    // controller 复用同一个实例，每次打开都从空开始，不残留上次输入
    this.input = '';
  }

  private confirm(): void {
    let minutes = parseInt(this.input);
    if (Number.isNaN(minutes) || minutes < 1 || minutes > 1440) {
      this.getUIContext().getPromptAction().showToast({
        message: '请输入 1–1440 之间的分钟数',
        duration: 2000
      });
      return;
    }
    this.onConfirm(minutes);
    this.controller?.close();
  }

  build() {
    Column() {
      Text('自定义刷新间隔')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Text('输入 1–1440 分钟（1 小时 = 60 分钟）；本地数据超过该时长后，进入页面会自动联网刷新')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 6 })

      TextInput({ text: this.input, placeholder: '分钟数，例如 45' })
        .type(InputType.Number)
        .fontSize(15)
        .height(44)
        .margin({ top: 14 })
        .onChange((value: string) => {
          this.input = value;
        })

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.bg_secondary'))
          .onClick(() => this.controller?.close())

        Button('确定')
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .fontColor($r('app.color.text_on_accent'))
          .backgroundColor($r('app.color.brand'))
          .onClick(() => this.confirm())
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function SettingsPageBuilder() {
  SettingsPage();
}
