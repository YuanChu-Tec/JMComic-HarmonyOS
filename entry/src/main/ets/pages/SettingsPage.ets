import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ThemeSetting } from '../common/ThemeSetting';
import { CacheManager } from '../common/CacheManager';
import { navPop } from '../common/NavHelper';

/**
 * 设置页面
 *
 * 汇总全局设置项：黑白模式、导出后自动删除下载缓存、清理缓存（自个人中心迁入）。
 * 后续新增设置项统一迁入此页。
 */
@Component
struct SettingsPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  /** 导出成功后自动删除下载缓存 */
  @State autoDeleteAfterExport: boolean = false;
  private cache: CacheManager | null = null;

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    this.autoDeleteAfterExport = this.cache.isAutoDeleteAfterExport();
  }

  onBack(): void {
    navPop();
  }

  /** 切换「导出成功后自动删除下载缓存」（整行可点，Toggle 仅作状态展示避免双通道） */
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

  onClearCache(): void {
    try {
      let context = getContext() as common.UIAbilityContext;
      let dirs = [context.cacheDir, context.filesDir];
      for (let dir of dirs) {
        this.deleteDirRecursive(dir);
      }
      // Toast 统一走 UIContext 形态（开发规范 §5.5，禁模块级 promptAction 直呼）
      this.getUIContext().getPromptAction().showToast({ message: '缓存已清理', duration: 2000 });
    } catch (e) {
      console.error('[SettingsPage] clear cache error:', JSON.stringify(e));
      this.getUIContext().getPromptAction().showToast({ message: '清理失败', duration: 2000 });
    }
  }

  private deleteDirRecursive(dirPath: string): void {
    try {
      if (!fileIo.accessSync(dirPath)) return;
      let names = fileIo.listFileSync(dirPath);
      for (let name of names) {
        let fullPath = dirPath + '/' + name;
        let stat = fileIo.statSync(fullPath);
        if (stat.isDirectory()) {
          this.deleteDirRecursive(fullPath);
          fileIo.rmdirSync(fullPath);
        } else {
          fileIo.unlinkSync(fullPath);
        }
      }
    } catch (e) {
      console.warn(`[SettingsPage] deleteDir ${dirPath} error:`, JSON.stringify(e));
    }
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

            // ── 缓存 ──
            Column() {
              Row() {
                Text('清理缓存')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
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
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function SettingsPageBuilder() {
  SettingsPage();
}
