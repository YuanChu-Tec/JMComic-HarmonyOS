import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ThemeSetting } from '../common/ThemeSetting';
import { CacheManager } from '../common/CacheManager';
import { navPop } from '../common/NavHelper';
import { HAIRLINE_BORDER } from '../common/UiEffects';

/**
 * 设置页面
 *
 * 汇总全局设置项：黑白模式、导出后自动删除下载缓存、清理缓存（仅清缓存目录并显示体积）。
 * 后续新增设置项统一迁入此页。
 */
@Component
struct SettingsPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  /** 导出成功后自动删除下载缓存 */
  @State autoDeleteAfterExport: boolean = false;
  /** 缓存目录体积文案（异步计算后回填） */
  @State cacheText: string = '计算中…';
  private cache: CacheManager | null = null;

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    this.autoDeleteAfterExport = this.cache.isAutoDeleteAfterExport();
    this.refreshCacheSize();
  }

  onBack(): void {
    navPop();
  }

  /** 切换「导出成功后自动删除下载缓存」（整行可点；Toggle 纯状态展示，见 build 内注释） */
  onToggleAutoDelete(): void {
    let next = !this.autoDeleteAfterExport;
    this.autoDeleteAfterExport = next;
    this.cache?.setAutoDeleteAfterExport(next);
    // Toast 统一走 UIContext 形态（开发规范 §5.5，禁模块级 promptAction 直呼）
    this.getUIContext().getPromptAction().showToast({
      message: next ? '已开启：导出成功后将自动清理下载缓存' : '已关闭',
      duration: 2000
    });
  }

  /** 清理缓存：仅清缓存目录（cacheDir），已下载内容（filesDir/JMComic/download）不受影响 */
  async onClearCache(): Promise<void> {
    let ok = await this.confirmDialog('清理缓存', '将清理图片缓存与导出临时文件，已下载内容不受影响。', '清理');
    if (!ok) return;
    try {
      let context = getContext() as common.UIAbilityContext;
      let freed = await this.clearDirChildren(context.cacheDir);
      // Toast 统一走 UIContext 形态（开发规范 §5.5，禁模块级 promptAction 直呼）
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
          .backgroundColor($r('app.color.overlay_bg'))
          .borderRadius(18)
          .border(HAIRLINE_BORDER)
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

        // ── 内容区 ──
        Scroll() {
          Column() {
            // ── 黑白模式 ──
            ThemeSetting()

            // ── 导出成功后自动删除下载缓存 ──
            Column() {
              Row() {
                Column() {
                  Text('导出成功后自动删除下载缓存')
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                  Text('导出压缩包成功后自动清理本地已下载文件，仅保留下载记录；如需再次导出请重新下载')
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
            .margin({ top: 16 })

            // ── 缓存（体积异步统计，参考 Cimoc；仅清 cacheDir，下载内容不在此清理） ──
            Column() {
              Row() {
                Text('清理缓存')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)

                Text(this.cacheText)
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16, bottom: 16 })
              .onClick(() => this.onClearCache())
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ top: 16 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
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
    .onShown(() => this.refreshCacheSize())
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function SettingsPageBuilder() {
  SettingsPage();
}
