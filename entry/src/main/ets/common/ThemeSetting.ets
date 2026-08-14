/**
 * ThemeSetting 主题设置组件
 *
 * 三个选项：跟随系统 / 浅色 / 深色。
 * 通过 ThemeManager 切换并持久化，选择后即时生效（resource 颜色自动切换）。
 */
import { ThemeManager, ThemeModeKey } from '../common/ThemeManager';

interface ThemeOption {
  key: ThemeModeKey;
  label: string;
}

const THEME_OPTIONS: ThemeOption[] = [
  { key: 'system', label: '跟随系统' },
  { key: 'light', label: '浅色' },
  { key: 'dark', label: '深色' },
];

@Component
export struct ThemeSetting {
  @StorageProp('themeMode') @Watch('onModeChanged') themeMode: string = 'system';
  private themeManager: ThemeManager = ThemeManager.getInstance();

  onModeChanged(): void {
    // AppStorage 值来自其他进程（如系统切换）时刷新 UI
  }

  async onSelect(mode: ThemeModeKey): Promise<void> {
    if (this.themeMode === mode) return;
    await this.themeManager.setMode(mode);
  }

  build() {
    Column() {
      Row() {
        Text('黑白模式')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')

      Row({ space: 8 }) {
        ForEach(THEME_OPTIONS, (opt: ThemeOption) => {
          Text(opt.label)
            .fontSize(14)
            .fontColor(this.themeMode === opt.key ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor(this.themeMode === opt.key ? $r('app.color.brand') : $r('app.color.bg_secondary'))
            .borderRadius(16)
            .onClick(() => {
              this.onSelect(opt.key);
            })
        }, (opt: ThemeOption) => opt.key)
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ top: 16 })
  }
}
