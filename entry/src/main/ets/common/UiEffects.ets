/**
 * 视觉效果共享件：沉浸光感材质（API 26）与玻璃发丝描边。
 *
 * 官方约束（开发规范核验三分法结论，2026-11-25）：沉浸光感材质仅在
 * Navigation/NavDestination 标题栏或底部 TabBar 生效，内容区设置不生效
 * （日志 Material inactive: out of scope）；本项目全部页面为自绘顶栏，
 * 内容区一律改用「半透明底 + 发丝描边」玻璃边缘承担可视化边缘职责。
 * getLightMaterial() 保留三重门控（模拟器 / 能力探测 / try-catch），
 * 供标题栏类区域与后续官方放开生效范围后直接复用。
 */

import { uiMaterial } from '@kit.ArkUI';
import { DeviceUtils } from 'common';

let cachedMaterial: uiMaterial.ImmersiveMaterial | undefined | null = null;

/**
 * 沉浸光感材质单例（API 26 uiMaterial.ImmersiveMaterial + 光感交互反馈）。
 * 模拟器 / 低版本运行时 / 不支持设备返回 undefined，调用方回退纯色底。
 */
export function getLightMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  if (cachedMaterial !== null) {
    return cachedMaterial;
  }
  cachedMaterial = createLightMaterial();
  return cachedMaterial;
}

function createLightMaterial(): uiMaterial.ImmersiveMaterial | undefined {
  if (DeviceUtils.isEmulator()) {
    return undefined;
  }
  try {
    // 低版本运行时无此模块/接口，typeof 探测 + try/catch 双保险
    if (typeof uiMaterial.isImmersiveMaterialSupported === 'function' && !uiMaterial.isImmersiveMaterialSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      lightEffect: { color: Color.White }
    });
  } catch (e) {
    console.warn('[UiEffects] immersive material unsupported:', JSON.stringify(e));
    return undefined;
  }
}

/** 发丝描边：0.5vp 系统分割线色，随深浅色自适应，仅做轮廓提示 */
export const HAIRLINE_BORDER: BorderOptions = {
  width: 0.5,
  color: $r('sys.color.comp_divider')
};
