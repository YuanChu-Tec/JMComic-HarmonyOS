/**
 * 智感握姿传感层：订阅/退订系统握持事件（左手/右手感知），能力防御。
 * 移植自参考项目 Cimoc（HoldingHandleUtil，机制一致）：业务侧只调 start(callback) / stop()，
 * 不要绕过它直接调 motion.on。需 module.json5 声明 ohos.permission.DETECT_GESTURE；
 * 设备不支持时静默降级（按钮恒停默认右下），不影响任何其他功能。
 * 真机验证：hilog | grep HoldingHandleUtil
 */

import { motion } from '@kit.MultimodalAwarenessKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HoldingHandleUtil';
const DOMAIN = 0x4514;

export type HoldingHandCallback = (status: motion.HoldingHandStatus) => void;

class _HoldingHandleUtil {
  // 缓存系统能力是否可用（防重复注册）
  private isCapabilityAvailable: boolean = false;
  private callback: HoldingHandCallback | null = null;

  /**
   * 启动握持检测。设备不支持 MultimodalAwareness.Motion（或返回 801）时静默降级（不注册、只告警）。
   */
  start(callback: HoldingHandCallback): void {
    if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      this.isCapabilityAvailable = false;
      hilog.warn(DOMAIN, TAG, '当前设备不支持握持检测 API');
      return;
    }
    if (this.isCapabilityAvailable) {
      hilog.info(DOMAIN, TAG, '握持检测已在运行中');
      return;
    }
    this.isCapabilityAvailable = true;
    this.callback = callback;
    try {
      motion.on('holdingHandChanged', (status: motion.HoldingHandStatus) => {
        this.logStatus(status);
        if (this.callback) {
          this.callback(status);
        }
      });
      hilog.info(DOMAIN, TAG, '握持检测已启动');
    } catch (e) {
      // 不支持的设备可能抛 801（capability not supported），降级为不可用
      hilog.error(DOMAIN, TAG, `开启握持事件失败: ${JSON.stringify(e)}`);
      this.isCapabilityAvailable = false;
    }
  }

  stop(): void {
    if (!this.isCapabilityAvailable) {
      return;
    }
    try {
      if (canIUse('SystemCapability.MultimodalAwareness.Motion')) {
        motion.off('holdingHandChanged');
        hilog.info(DOMAIN, TAG, '握持检测已停止');
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `关闭握持事件失败: ${JSON.stringify(error)}`);
    } finally {
      this.isCapabilityAvailable = false;
      this.callback = null;
    }
  }

  private logStatus(status: motion.HoldingHandStatus): void {
    let str = '';
    switch (status) {
      case motion.HoldingHandStatus.NOT_HELD: str = '未握持'; break;
      case motion.HoldingHandStatus.LEFT_HAND_HELD: str = '左手握持'; break;
      case motion.HoldingHandStatus.RIGHT_HAND_HELD: str = '右手握持'; break;
      case motion.HoldingHandStatus.BOTH_HANDS_HELD: str = '双手握持'; break;
      default: str = `${status}`; break;
    }
    hilog.debug(DOMAIN, TAG, `状态变化: ${str}`);
  }
}

export const HoldingHandleUtil = new _HoldingHandleUtil();
