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
 * - 内容刷新：刷新内容（字段/封面/章节图片各多久重建一次；页面始终联网）
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
  /** 刷新内容 3 项的重建间隔（分钟，-1 表示每次都重建，0 表示不自动重建） */
  @State contentFieldMinutes: number = CacheManager.DEFAULT_CONTENT_TTL_MINUTES;
  @State contentCoverMinutes: number = CacheManager.DEFAULT_CONTENT_TTL_MINUTES;
  @State contentImageMinutes: number = CacheManager.DEFAULT_CONTENT_TTL_MINUTES;
  /** 内容间隔半模态：可见性 + 正在编辑的 kind / 标题 */
  @State intervalSheetVisible: boolean = false;
  @State editingKind: string = '';
  @State editingTitle: string = '';
  /** 统一图片仓库体积（异步计算后回填） */
  @State librarySizeText: string = '计算中…';
  /** 供并排分段按钮使用；0 表示不自动清理 */
  private readonly readCacheOptions: number[] = [0, 3, 7, 30];
  /** 已导出保留的哨兵值：-1 表示打包成功后立即删除（不是天数） */
  private readonly exportedDeleteNow: number = -1;
  private readonly exportedOptions: number[] = [0, 7, 30, -1];
  /** 内容项重建间隔候选：第一个是「立即刷新」，最后一个是「不自动」（0） */
  private readonly intervalOptions: number[] =
    [CacheManager.IMMEDIATE_REFRESH_MINUTES, 30, 60, 120, 360, 720, 1440, 0];
  private cache: CacheManager | null = null;
  /** 自定义分钟弹窗的落点：内容种类 */
  private refreshTargetKind: string = CacheManager.CONTENT_FIELD;
  /** 自定义分钟数弹窗（输入框每次打开重新挂载，因此 controller 可复用） */
  private refreshDialog: CustomDialogController = new CustomDialogController({
    builder: RefreshMinutesDialog({
      onConfirm: (minutes: number) => this.applyCustomMinutes(minutes)
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
    this.contentFieldMinutes = this.cache.getContentRefreshMinutesOf(CacheManager.CONTENT_FIELD);
    this.contentCoverMinutes = this.cache.getContentRefreshMinutesOf(CacheManager.CONTENT_COVER);
    this.contentImageMinutes = this.cache.getContentRefreshMinutesOf(CacheManager.CONTENT_IMAGE);
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

  /** 自定义分钟弹窗回调：写到当前编辑的内容项 */
  private applyCustomMinutes(minutes: number): void {
    this.setContentMinutes(this.refreshTargetKind, minutes);
  }

  /** 读某内容项的间隔（@Builder 里按 kind 取，保证依赖到对应的 @State） */
  private contentMinutes(kind: string): number {
    if (kind === CacheManager.CONTENT_FIELD) return this.contentFieldMinutes;
    if (kind === CacheManager.CONTENT_COVER) return this.contentCoverMinutes;
    return this.contentImageMinutes;
  }

  /** 写内容项间隔；选中即保存并同步给判定方 */
  private setContentMinutes(kind: string, minutes: number): void {
    if (this.contentMinutes(kind) === minutes) return;
    if (kind === CacheManager.CONTENT_FIELD) {
      this.contentFieldMinutes = minutes;
    } else if (kind === CacheManager.CONTENT_COVER) {
      this.contentCoverMinutes = minutes;
    } else {
      this.contentImageMinutes = minutes;
    }
    this.cache?.saveContentRefreshMinutesOf(kind, minutes);
  }

  /** 行内展示的间隔 */
  private intervalText(kind: string): string {
    return this.refreshText(this.contentMinutes(kind));
  }

  /** 打开内容项间隔半模态 */
  private openIntervalSheet(kind: string, title: string): void {
    this.editingKind = kind;
    this.editingTitle = title;
    this.intervalSheetVisible = true;
  }

  /** 半模态里的档位文案 */
  private intervalOptionText(minutes: number): string {
    return this.refreshText(minutes);
  }

  /** 内容项重建间隔半模态 */
  @Builder
  IntervalSheetBuilder() {
    Column() {
      Text(`${this.editingTitle} · 重建间隔`)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Text('页面每次进入都会联网；这里控制这类产物最多多久重建一次')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 6 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.intervalOptions, (minutes: number) => {
          Text(this.intervalOptionText(minutes))
            .fontSize(12)
            .fontColor(this.contentMinutes(this.editingKind) === minutes
              ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(this.contentMinutes(this.editingKind) === minutes
              ? $r('app.color.brand') : $r('app.color.bg_secondary'))
            .margin({ right: 8, top: 8 })
            .onClick(() => {
              this.setContentMinutes(this.editingKind, minutes);
              this.intervalSheetVisible = false;
            })
        }, (minutes: number) => `interval_${minutes}`)

        Text('自定义…')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor($r('app.color.bg_secondary'))
          .margin({ right: 8, top: 8 })
          .onClick(() => {
            this.intervalSheetVisible = false;
            this.refreshTargetKind = this.editingKind;
            // 等半模态收起再弹自定义，避免两个浮层抢焦点
            setTimeout(() => {
              this.refreshDialog.open();
            }, 200);
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Button('完成')
        .fontSize(15)
        .fontColor($r('app.color.text_on_accent'))
        .width('100%')
        .height(42)
        .borderRadius(21)
        .backgroundColor($r('app.color.brand'))
        .margin({ top: 16 })
        .onClick(() => {
          this.intervalSheetVisible = false;
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 8, bottom: 16 })
  }

  private refreshText(minutes: number): string {
    if (minutes === CacheManager.IMMEDIATE_REFRESH_MINUTES) {
      return '立即刷新';
    }
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

  /** 清除全部漫画的阅读记录：已读标记、最后阅读章节与阅读位置全清 */
  private async onClearReadHistory(): Promise<void> {
    let ok = await this.confirmDialog('清除已读记录',
      '将清除所有漫画的已读标记、最后阅读章节与阅读位置。章节列表不再显示已读，再打开漫画从第一章第 1 页开始。',
      '清除');
    if (!ok) return;
    try {
      if (!this.cache) {
        this.cache = await CacheManager.getInstance();
      }
      let removed = this.cache.clearAllReadHistory();
      this.getUIContext().getPromptAction().showToast({
        message: removed > 0 ? `已清除 ${removed} 本漫画的已读记录` : '没有已读记录',
        duration: 2000
      });
    } catch (e) {
      console.error('[SettingsPage] clear read history error:', JSON.stringify(e));
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
              // 刷新内容：联网拿到数据后，决定哪一层产物重建；三项各有自己的间隔
              Column() {
                Text('刷新内容')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text('页面每次进入都会联网；这里控制每类产物最多多久重建一次，点某行可改')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 4 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 14, bottom: 2 })

              ContentRow({
                title: '漫画字段',
                desc: '标题、作者、简介、统计与章节目录',
                intervalLabel: this.intervalText(CacheManager.CONTENT_FIELD),
                onInterval: () => this.openIntervalSheet(CacheManager.CONTENT_FIELD, '漫画字段')
              })
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              ContentRow({
                title: '封面',
                desc: '服务器换了封面图才重下；未到期沿用本地旧图',
                intervalLabel: this.intervalText(CacheManager.CONTENT_COVER),
                onInterval: () => this.openIntervalSheet(CacheManager.CONTENT_COVER, '封面')
              })
              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })
              ContentRow({
                title: '章节图片',
                desc: '作品换图时重新下载页图；会消耗额外流量',
                intervalLabel: this.intervalText(CacheManager.CONTENT_IMAGE),
                onInterval: () => this.openIntervalSheet(CacheManager.CONTENT_IMAGE, '章节图片')
              })

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              // 下拉刷新只换列表成员，不重建已有作品
              Text('下拉刷新只替换列表成员与顺序，不会重建已有作品的字段与封面；内容项的间隔在下一次联网时生效')
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
                Text('按整部漫画清理：整本的阅读缓存一起删，阅读记录与已读标记保留')
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

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              Row() {
                Column() {
                  Text('已读记录')
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                  Text('清除所有漫画的已读标记、最后阅读章节与阅读位置')
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
              .onClick(() => this.onClearReadHistory())
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
      .bindSheet(this.intervalSheetVisible!!, this.IntervalSheetBuilder(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: true,
        preferType: SheetType.BOTTOM
      })
    }
    .hideTitleBar(true)
    .onShown(() => {
      this.refreshCacheSize();
      this.refreshLibrarySize();
    })
  }
}

/**
 * 「刷新内容」的一行：标题 + 说明 + 右侧间隔标签（点开可改）。
 *
 * 独立组件而非 @Builder：@Builder 多次调用会共用同一份参数上下文，
 * 参数在状态变化后按最后一次调用求值，表现为多行联动。
 * intervalLabel 走 @Prop，父页面状态一变就同步到对应行。
 */
@Component
struct ContentRow {
  title: string = '';
  desc: string = '';
  /** 行内间隔文案（当前生效值） */
  @Prop intervalLabel: string = '';
  onInterval: () => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        Text(this.desc)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.intervalLabel)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor($r('app.color.bg_secondary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => this.onInterval())
  }
}

/**
 * 自定义内容项重建间隔（分钟）
 * 只负责输入与校验，落库与生效由 SettingsPage.setContentMinutes 完成
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
