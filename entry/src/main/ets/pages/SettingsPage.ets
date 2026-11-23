import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ThemeSetting } from '../common/ThemeSetting';
import { CacheManager } from '../common/CacheManager';
import { ComicLibrary } from '../common/ComicLibrary';
import { ComicRealtimeStore } from '../models/ComicAlbumRealtime';
import { navPop } from '../common/NavHelper';

/**
 * 设置页面
 *
 * 按用户操作对象分组：
 * - 显示：黑白模式
 * - 漫画图片：仓库占用、保留策略、导出后自动删除、强制清空
 * - 存储清理：临时缓存（cacheDir，不碰漫画图片）
 * - 阅读：阅读位置清除（已读标记保留）
 */
@Component
struct SettingsPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  /** 导出成功后自动删除下载缓存 */
  @State autoDeleteAfterExport: boolean = false;
  /** 缓存目录体积文案（异步计算后回填） */
  @State cacheText: string = '计算中…';
  /** 图片仓库保留策略（0 表示不自动清理） */
  @State readCacheDays: number = 7;
  @State exportedDays: number = 0;
  /** 统一图片仓库体积（异步计算后回填） */
  @State librarySizeText: string = '计算中…';
  /** 供并排分段按钮使用；0 表示不自动清理 */
  private readonly readCacheOptions: number[] = [0, 3, 7, 30];
  private readonly exportedOptions: number[] = [0, 7, 30];
  private cache: CacheManager | null = null;

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    this.autoDeleteAfterExport = this.cache.isAutoDeleteAfterExport();
    this.readCacheDays = this.cache.getReadCacheDays();
    this.exportedDays = this.cache.getExportedDays();
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

  /** 切换「导出成功后自动删除下载缓存」（整行可点；Toggle 纯状态展示，见 build 内注释） */
  onToggleAutoDelete(): void {
    let next = !this.autoDeleteAfterExport;
    this.autoDeleteAfterExport = next;
    this.cache?.setAutoDeleteAfterExport(next);
    this.getUIContext().getPromptAction().showToast({
      message: next ? '已开启：导出成功后将自动清理下载缓存' : '已关闭',
      duration: 2000
    });
  }

  /** 阅读缓存保留：按钮直接选中指定天数 */
  private setReadCacheDays(days: number): void {
    if (this.readCacheDays === days) return;
    this.readCacheDays = days;
    this.cache?.saveReadCacheDays(days);
  }

  /** 已导出保留：按钮直接选中指定天数 */
  private setExportedDays(days: number): void {
    if (this.exportedDays === days) return;
    this.exportedDays = days;
    this.cache?.saveExportedDays(days);
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

  /** 清理缓存：仅清临时目录（cacheDir），统一图片仓库中的漫画图片不受影响 */
  async onClearCache(): Promise<void> {
    let ok = await this.confirmDialog('清理缓存',
      '仅清理应用临时文件，不会删除任何漫画图片（包括已缓存和已下载的内容）。', '清理');
    if (!ok) return;
    try {
      let context = getContext() as common.UIAbilityContext;
      let freed = await this.clearDirChildren(context.cacheDir);
      // cacheDir 已清空，实时数据仓库的内存映射同步失效
      ComicRealtimeStore.getInstance().then(store => store.invalidateAll());
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

  /** 清除全部漫画的阅读位置；已读章节标记保留 */
  private async onClearReadPositions(): Promise<void> {
    let ok = await this.confirmDialog('清除阅读位置',
      '将清除所有漫画的上次阅读页码与章节；已读章节标记保留。下次打开漫画将从头开始。',
      '清除');
    if (!ok) return;
    try {
      if (!this.cache) {
        this.cache = await CacheManager.getInstance();
      }
      let removed = this.cache.clearAllReadPositions();
      this.getUIContext().getPromptAction().showToast({
        message: removed > 0 ? `已清除 ${removed} 本漫画的阅读位置` : '没有阅读位置记录',
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
                Text('已导出压缩包的章节图片；未导出的下载永不自动清理')
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

              Divider().height(1).color($r('app.color.divider')).margin({ left: 16 })

              // 导出成功后自动删除
              Row() {
                Column() {
                  Text('导出成功后自动删除')
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                  Text('导出压缩包成功后清理本地图片，仅保留下载记录；如需再次导出请重新下载')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: this.autoDeleteAfterExport })
                  .selectedColor($r('app.color.brand'))
                  .margin({ left: 12 })
                  // Toggle 会吞掉点击、不冒泡到整行 onClick（模拟器实测）：
                  // 直接点开关只翻视觉不写状态。禁其自身命中，由整行单通道切换。
                  .hitTestBehavior(HitTestMode.None)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => this.onToggleAutoDelete())
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
                  Text('仅清临时文件，不删除任何漫画图片')
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
                  Text('清除所有漫画的上次阅读页码与章节，已读标记保留')
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
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function SettingsPageBuilder() {
  SettingsPage();
}
