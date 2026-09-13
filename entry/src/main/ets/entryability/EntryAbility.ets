import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ThemeManager } from '../common/ThemeManager';
import { UpdateManager, RELEASES_PAGE_URL } from '../common/UpdateManager';
import { CacheManager } from '../common/CacheManager';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onConfigurationUpdate(config: Configuration): void {
    // 系统深色/浅色切换时，若用户选择了「跟随系统」则同步更新应用主题
    ThemeManager.getInstance().onSystemConfigurationChange();
    hilog.info(DOMAIN, 'testTag', 'onConfigurationUpdate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.getMainWindow((err, windowClass) => {
      let errCode: number = err.code;
      if (errCode) {
        hilog.error(DOMAIN, 'testTag', 'Failed to obtain the main window. Cause: ' + JSON.stringify(err));
        return;
      }

      // 设置窗口为全屏沉浸式模式
      windowClass.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(DOMAIN, 'testTag', 'Succeeded in setting the window layout to full-screen mode.');
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to set fullscreen. Cause:' + JSON.stringify(e));
      });

      // 获取状态栏区域高度
      let notificationArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      let topHeight = px2vp(notificationArea.topRect.height);
      AppStorage.setOrCreate('topSafeHeight', topHeight);

      // 获取导航栏区域高度
      let navigationArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      let bottomHeight = px2vp(navigationArea.bottomRect.height);
      AppStorage.setOrCreate('bottomSafeHeight', bottomHeight);

      hilog.info(DOMAIN, 'testTag', `topSafeHeight=${topHeight}, bottomSafeHeight=${bottomHeight}`);
    });

    // 先应用用户保存的主题（跟随系统/浅色/深色），再加载页面
    ThemeManager.getInstance().init().finally(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
        // 页面加载完成后再检查更新，避免弹窗时 UI 上下文还未就绪
        this.checkAppUpdate(windowStage);
      });
    });
  }

  /**
   * 启动时检查版本更新：当前版本落后于最新版本则弹窗提示
   */
  private async checkAppUpdate(windowStage: window.WindowStage): Promise<void> {
    let mgr = UpdateManager.getInstance();
    let current = mgr.getCurrentVersion();
    let latest = await mgr.fetchLatestVersion();
    if (!mgr.isNewer(latest, current)) {
      hilog.info(DOMAIN, 'testTag', `No update available, current=${current}, latest=${latest}`);
      return;
    }

    let cache = await CacheManager.getInstance(this.context);
    // 用户已忽略过该版本，不再提示（换版本号后会重新提示）
    if (cache.getSkipUpdateVersion() === latest) {
      hilog.info(DOMAIN, 'testTag', `Update ${latest} was skipped by user`);
      return;
    }

    try {
      let uiContext = windowStage.getMainWindowSync().getUIContext();
      let result = await uiContext.getPromptAction().showDialog({
        title: '发现新版本',
        message: `当前版本：JMComic ${current}\n最新版本：${latest}\n\n是否前往下载更新？`,
        buttons: [
          { text: '取消', color: '#999999' },
          { text: '忽略此版本', color: '#999999' },
          { text: '前往下载', color: '#FF5A5F' }
        ]
      });
      if (result.index === 1) {
        cache.setSkipUpdateVersion(latest);
      } else if (result.index === 2) {
        this.openUrl(RELEASES_PAGE_URL);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Show update dialog failed: ' + JSON.stringify(err));
    }
  }

  /** 用系统浏览器打开下载页 */
  private openUrl(url: string): void {
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browser'],
      uri: url
    };
    this.context.startAbility(want).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Open download page failed: ' + err.message);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
