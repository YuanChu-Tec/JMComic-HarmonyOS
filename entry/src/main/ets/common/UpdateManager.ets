import { bundleManager } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';

/**
 * 版本更新管理
 *
 * 职责：
 * - 读取本机已安装版本（bundleManager）
 * - 拉取 GitHub 最新 Release 版本号
 * - 版本号比较，判断是否有新版本
 *
 * 被 EntryAbility（启动检查 + 弹窗）和 AboutPage（版本展示）共用，
 * 避免版本逻辑在多处重复。
 *
 * ── 版本号规范（务必遵守，否则更新判断会失效）──
 * - GitHub Release tag 严格使用 vX.Y.Z（X/Y/Z 纯数字），去掉 v 后必须与
 *   AppScope/app.json5 的 versionName 完全一致
 * - 禁止 release-1.0.9 / JMComic_1.0.9 之类前后缀
 * - 预发布一律标记为 GitHub pre-release，/releases/latest 接口会自动跳过
 * - 发版流程：先改 app.json5 的 versionName + versionCode → 打同名 tag → 发 Release
 *
 * ── 容错策略 ──
 * 版本号一律经 normalizeVersion() 提取第一段 x.y.z；解析不出则视为空，
 * isNewer() 直接返回 false —— 宁可不提示，也不基于脏数据误提示。
 */

/** Releases 页面（供用户点击跳转下载） */
export const RELEASES_PAGE_URL: string = 'https://github.com/YuanChu-Tec/JMComic-HarmonyOS/releases/latest';

/** GitHub 最新 Release 接口 */
const LATEST_RELEASE_API: string = 'https://api.github.com/repos/YuanChu-Tec/JMComic-HarmonyOS/releases/latest';

interface GitHubRelease {
  tag_name: string;
  name: string;
}

export class UpdateManager {
  private static instance: UpdateManager | null = null;

  static getInstance(): UpdateManager {
    if (UpdateManager.instance === null) {
      UpdateManager.instance = new UpdateManager();
    }
    return UpdateManager.instance;
  }

  /** 本机已安装版本（已归一化），读取失败或格式非法返回空串 */
  getCurrentVersion(): string {
    try {
      let info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return this.normalizeVersion(info.versionName);
    } catch (err) {
      console.error('[UpdateManager] 读取当前版本失败: ' + JSON.stringify(err));
      return '';
    }
  }

  /** 拉取最新版本号（已归一化），失败或格式非法返回空串 */
  async fetchLatestVersion(): Promise<string> {
    let request = http.createHttp();
    try {
      let response = await request.request(LATEST_RELEASE_API, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/vnd.github+json' },
        connectTimeout: 10000,
        readTimeout: 10000,
      });
      if (response.responseCode !== 200) {
        return '';
      }
      let data = JSON.parse(response.result as string) as GitHubRelease;
      return this.normalizeVersion(data.tag_name || data.name || '');
    } catch (err) {
      console.error('[UpdateManager] 获取最新版本失败: ' + JSON.stringify(err));
      return '';
    } finally {
      request.destroy();
    }
  }

  /**
   * 归一化版本号：从任意字符串中抽出第一段 x.y.z（要求至少两段）
   * 'v1.0.9' / 'release-1.0.9' / 'JMComic_1.0.9' → '1.0.9'
   * 解析不出返回空串，调用方按"无版本"处理（不提示更新）
   */
  normalizeVersion(raw: string): string {
    if (!raw) {
      return '';
    }
    let matched = raw.match(/\d+(?:\.\d+)+/);
    if (!matched) {
      console.warn(`[UpdateManager] 无法解析版本号: ${raw}`);
      return '';
    }
    return matched[0];
  }

  /** 是否存在新版本；任一版本号为空（含解析失败）时返回 false */
  isNewer(latest: string, current: string): boolean {
    if (!latest || !current) {
      return false;
    }
    return this.compareVersion(latest, current) > 0;
  }

  /** 比较版本号：1 表示 a>b，0 表示相等，-1 表示 a<b */
  compareVersion(a: string, b: string): number {
    let pa: string[] = a.split('.');
    let pb: string[] = b.split('.');
    let len: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      let na: number = parseInt(pa[i] ? pa[i] : '0') || 0;
      let nb: number = parseInt(pb[i] ? pb[i] : '0') || 0;
      if (na > nb) {
        return 1;
      }
      if (na < nb) {
        return -1;
      }
    }
    return 0;
  }
}
