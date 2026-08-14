/**
 * ThemeManager 全局主题（黑白/深色模式）管理器
 *
 * 支持三种模式：
 *  - 'system'  跟随系统深色/浅色
 *  - 'light'   强制浅色
 *  - 'dark'    强制深色
 *
 * 通过调用 UIAbilityContext.setColorMode() 让系统资源（resource 目录下的
 * base/dark 颜色）自动切换，同时把当前模式写入 AppStorage('themeMode'),
 * 供页面中需要动态计算的资源引用使用。
 *
 * 颜色模式说明：
 *  - COLOR_MODE_LIGHT(1) / COLOR_MODE_DARK(0) 强制应用为对应模式
 *  - COLOR_MODE_NOT_SET(-1) 不覆盖系统，资源自动在 base/dark 之间切换（即跟随系统）
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type ThemeModeKey = 'system' | 'light' | 'dark';

/** 持久化偏好文件名 */
const THEME_PREF_NAME: string = 'JMComicTheme';
/** 偏好键 */
const THEME_MODE_KEY: string = 'themeMode';

/**
 * 根据用户选择解析实际生效的颜色模式
 * @param mode 用户偏好
 */
export function resolveColorMode(mode: ThemeModeKey): ConfigurationConstant.ColorMode {
  if (mode === 'light') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  if (mode === 'dark') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  // system：跟随系统（NOT_SET 表示不覆盖，资源自动切换）
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

export class ThemeManager {
  private static instance: ThemeManager;

  public static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  /** 是否已初始化完成（preferences + AppStorage 就绪） */
  private initialized: boolean = false;
  /** 等待初始化 / 正在应用主题的 Promise */
  private initPromise: Promise<void> | null = null;

  /**
   * 初始化：读取持久化的主题偏好并应用。
   * 需在应用启动、Ability 创建时调用一次。
   */
  public async init(): Promise<void> {
    if (this.initialized) return;
    if (this.initPromise) return this.initPromise;
    this.initPromise = this._init();
    await this.initPromise;
  }

  private async _init(): Promise<void> {
    try {
      let mode: ThemeModeKey = await this.loadMode();
      this.applyMode(mode);
      // 将用户选择的模式存到 AppStorage，供 UI 展示当前选项
      AppStorage.setOrCreate<ThemeModeKey>('themeMode', mode);
      this.initialized = true;
    } catch (err) {
      console.warn('[ThemeManager] init error:', JSON.stringify(err));
      // 初始化失败时按跟随系统兜底
      try {
        let ctx = getContext() as common.UIAbilityContext;
        ctx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      } catch (_e) {
      }
      this.initialized = true;
    }
  }

  /** 读取偏好模式，默认 system */
  private async loadMode(): Promise<ThemeModeKey> {
    try {
      let prefs = await preferences.getPreferences(getContext() as common.UIAbilityContext, THEME_PREF_NAME);
      let mode = prefs.getSync(THEME_MODE_KEY, 'system') as string;
      if (mode === 'light' || mode === 'dark' || mode === 'system') {
        return mode;
      }
      return 'system';
    } catch (err) {
      console.warn('[ThemeManager] loadMode error:', JSON.stringify(err));
      return 'system';
    }
  }

  /** 读取系统当前是否为深色模式 */
  public isSystemDark(): boolean {
    try {
      let ctx = getContext() as common.UIAbilityContext;
      return ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (err) {
      console.warn('[ThemeManager] isSystemDark error:', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 应用某种模式到应用上下文，并同步 AppStorage。
   * @param mode 用户选择的模式
   *
   * 注意：setColorMode 会触发系统 ConfigurationChange，进而导致页面整体重渲染。
   * 因此这里只在「模式真正发生变化」时才调用，避免在 onConfigurationUpdate
   * 回调里再次 setColorMode 造成「配置变更 -> 重渲染 -> 配置变更」的死循环。
   */
  public applyMode(mode: ThemeModeKey): void {
    let target: ConfigurationConstant.ColorMode = resolveColorMode(mode);
    let shouldSet: boolean = true;
    try {
      let ctx = getContext() as common.UIAbilityContext;
      let current: ConfigurationConstant.ColorMode | undefined = ctx.config.colorMode;
      shouldSet = current !== target;
    } catch (err) {
      console.warn('[ThemeManager] applyMode read colorMode error:', JSON.stringify(err));
    }
    if (shouldSet) {
      try {
        let ctx = getContext() as common.UIAbilityContext;
        ctx.setColorMode(target);
      } catch (err) {
        console.warn('[ThemeManager] applyMode setColorMode error:', JSON.stringify(err));
      }
    }
    AppStorage.setOrCreate<ThemeModeKey>('themeMode', mode);
  }

  /** 切换到指定模式并持久化 */
  public async setMode(mode: ThemeModeKey): Promise<void> {
    this.applyMode(mode);
    try {
      let prefs = await preferences.getPreferences(getContext() as common.UIAbilityContext, THEME_PREF_NAME);
      await prefs.put(THEME_MODE_KEY, mode);
      await prefs.flush();
    } catch (err) {
      console.warn('[ThemeManager] setMode persist error:', JSON.stringify(err));
    }
  }

  /** 获取当前保存的用户模式 */
  public async getSavedMode(): Promise<ThemeModeKey> {
    return this.loadMode();
  }

  /** 处理系统配置变化（如系统切换深色/浅色），仅 mode=system 时跟随更新 */
  public async onSystemConfigurationChange(): Promise<void> {
    let currentMode = AppStorage.get<ThemeModeKey>('themeMode');
    if (currentMode === undefined || currentMode === null) {
      // AppStorage 尚未初始化，读取偏好判断
      let mode = await this.loadMode();
      // system 模式无需任何 setColorMode 操作，跟随系统即可
      return;
    }
    // 只有「跟随系统」会被系统配置变更通知到；此时绝不能再次调用
    // setColorMode（那正是触发本次配置变更的源头），否则会陷入死循环。
    // 跟随系统 = 什么都不做，资源会由框架自动在 base/dark 之间切换。
  }
}
