/**
 * Navigation 路由辅助：全局经 AppStorage 单例获取 NavPathStack。
 * 依据 docs/Navigation路由规范.md §3「子页获取 NavPathStack 方式2」：
 * 服务层/普通组件（CommentItem、JmAlbumCard 等）不做耦合注入，统一走这里。
 * Index 在 aboutToAppear 中把根容器实例写入 AppStorage('navPathStack')。
 */

/** 取全局导航栈；未初始化时返回 null（调用方无需判空，navPush 内部已兜底） */
export function getNavPathStack(): NavPathStack | null {
  return AppStorage.get<NavPathStack>('navPathStack') ?? null;
}

/** 跳转到指定 NavDestination（router.pushUrl 的替代） */
export function navPush(name: string, param?: Object | null): void {
  let stack = getNavPathStack();
  if (!stack) {
    console.error('[Nav] navPathStack 未初始化，跳转被忽略: ' + name);
    return;
  }
  stack.pushPathByName(name, param ?? null);
}

/** 自替换当前页（router.replaceUrl 的替代），用于同型页面防栈堆叠跳转 */
export function navReplace(name: string, param?: Object | null): void {
  let stack = getNavPathStack();
  if (!stack) {
    console.error('[Nav] navPathStack 未初始化，替换被忽略: ' + name);
    return;
  }
  stack.replacePathByName(name, param ?? null);
}

/** 返回上一页（router.back 的替代）；栈空时等价于无操作 */
export function navPop(): void {
  getNavPathStack()?.pop();
}
