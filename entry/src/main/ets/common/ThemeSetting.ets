/**
 * ThemeSetting 主题设置组件
 *
 * 三个选项：跟随系统 / 浅色 / 深色，Select 下拉选择。
 * 通过 ThemeManager 切换并持久化，选择后即时生效（resource 颜色自动切换）。
 * 预填充：'themeMode' 由 ThemeManager 在应用启动时写入 AppStorage（早于本组件创建），
 * @StorageProp 首帧即持有已保存值，Select 的选中项与显示文案据此初始化——
 * 不会出现「打开时下拉框空白、直到用户手动选择才有值」的缺省态。
 */
import { ThemeManager, ThemeModeKey } from '../common/ThemeManager';

@Component
export struct ThemeSetting {
  @StorageProp('themeMode') @Watch('onModeChanged') themeMode: string = 'system';
  private themeManager: ThemeManager = ThemeManager.getInstance();
  // Select 选项与 ThemeModeKey 一一对应（下标即选中索引）
  private optionLabels: string[] = ['跟随系统', '浅色', '深色'];
  private optionKeys: ThemeModeKey[] = ['system', 'light', 'dark'];

  onModeChanged(): void {
    // AppStorage 值来自其他进程（如系统切换）时刷新 UI
  }

  /** 当前模式 -> 选项下标（未知值兜底 0=跟随系统） */
  private currentIndex(): number {
    let idx = this.optionKeys.indexOf(this.themeMode as ThemeModeKey);
    return idx >= 0 ? idx : 0;
  }

  async onSelect(index: number): Promise<void> {
    let mode = this.optionKeys[index] ?? 'system';
    if (this.themeMode === mode) return;
    await this.themeManager.setMode(mode);
  }

  build() {
    Row() {
      Text('黑白模式')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Select(this.optionLabels.map((label: string): SelectOption => {
        return { value: label } as SelectOption;
      }))
        // 预填充：选中索引与显示文案均由已保存模式推导（两处同步，缺一就是空下拉）
        .selected(this.currentIndex())
        .value(this.optionLabels[this.currentIndex()])
        .fontColor($r('app.color.text_secondary'))
        .selectedOptionFontColor($r('app.color.brand'))
        .optionFontColor($r('app.color.text_primary'))
        .onSelect((index: number) => {
          this.onSelect(index);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ top: 16 })
  }
}
