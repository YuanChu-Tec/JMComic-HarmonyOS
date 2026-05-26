/**
 * 菜单项接口
 * 用于展开菜单、气泡菜单等组件
 */
export interface MenuItem {
  title?: string;
  text: string;
  action?: () => void;
}

/**
 * 菜单位置选项
 */
export interface MenuPosition {
  x: string | number;
  y: string | number;
}

/**
 * 构建展开菜单组件
 * @param menuItems 菜单项数组
 * @param position 菜单位置（默认为右上角）
 * @param onDismiss 菜单关闭回调
 */
@Builder
export function buildExpandedMenu(
  menuItems: MenuItem[],
  position: MenuPosition = { x: '100%', y: 56 },
  onDismiss?: () => void
) {
  Column() {
    Column() {
      Row() {
        ForEach(menuItems, (menuItem: MenuItem, itemIndex: number) => {
          Column({ space: 4 }) {
            if (menuItem.title) {
              Text(menuItem.title)
                .fontSize(12)
                .fontColor('#999999')
            }
            Text(menuItem.text)
              .fontSize(13)
              .fontColor('#333333')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .wordBreak(WordBreak.BREAK_ALL)
          }
          .layoutWeight(1)
          .padding(12)
          .alignItems(HorizontalAlign.Start)
          .onClick(() => {
            menuItem.action?.();
            onDismiss?.();
          })
          if (itemIndex < menuItems.length - 1) {
            Row()
              .width(1)
              .height('70%')
              .backgroundColor('#F2F2F7')
          }
        }, (menuItem: MenuItem, itemIndex: number) => itemIndex.toString())
      }
    }
    .width(300)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .shadow({
      radius: 16,
      color: 'rgba(0, 0, 0, 0.2)',
      offsetY: 4
    })
  }
  .position({ x: position.x, y: position.y })
  .translate({ x: typeof position.x === 'string' && position.x === '100%' ? -320 : 0, y: 0 })
  .zIndex(101)
}

/**
 * 构建菜单遮罩层（透明背景，点击关闭）
 * @param onDismiss 点击遮罩层时的回调
 */
@Builder
export function buildMenuOverlay(onDismiss: () => void) {
  Column()
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0)')
    .onClick(() => {
      onDismiss();
    })
}

/**
 * 线路数据
 */
export interface RouteColumn {
  title: string;
  routes: string[];
  selectedIndex: number; // -1 = 自动
  onSelect?: (index: number) => void;
}

/**
 * 构建线路选择菜单
 * @param columns 线路列数组（左列、右列）
 * @param position 菜单位置
 * @param onDismiss 菜单关闭回调
 */
@Builder
export function buildRouteMenu(
  columns: RouteColumn[],
  position: MenuPosition = { x: '100%', y: 56 },
  onDismiss: () => void
) {
  Column() {
    Column() {
      Row() {
        ForEach(columns, (col: RouteColumn, colIndex: number) => {
          Scroll() {
            Column({ space: 2 }) {
              Text(col.title)
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
              // 自动选项
              Row() {
                Text('自动')
                  .fontSize(12)
                  .fontColor(col.selectedIndex < 0 ? '#007AFF' : '#333333')
                  .fontWeight(col.selectedIndex < 0 ? FontWeight.Bold : FontWeight.Normal)
                if (col.selectedIndex < 0) {
                  Text(' ✓')
                    .fontSize(12)
                    .fontColor('#007AFF')
                }
              }
              .width('100%')
              .padding({ top: 4, bottom: 2 })
              .onClick(() => {
                col.onSelect?.(-1);
                onDismiss();
              })
              Row()
                .width('100%')
                .height(0.5)
                .backgroundColor('#F2F2F7')
              // 各线路
              ForEach(col.routes, (route: string, routeIndex: number) => {
                Row() {
                  Text(`线路${routeIndex + 1}`)
                    .fontSize(12)
                    .fontColor(col.selectedIndex === routeIndex ? '#007AFF' : '#333333')
                    .fontWeight(col.selectedIndex === routeIndex ? FontWeight.Bold : FontWeight.Normal)
                  if (col.selectedIndex === routeIndex) {
                    Text(' ✓')
                      .fontSize(12)
                      .fontColor('#007AFF')
                  }
                }
                .width('100%')
                .padding({ top: 4, bottom: 2 })
                .onClick(() => {
                  col.onSelect?.(routeIndex);
                  onDismiss();
                })
                Text(route)
                  .fontSize(11)
                  .fontColor('#999999')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .wordBreak(WordBreak.BREAK_ALL)
                  .width('100%')
                  .padding({ bottom: routeIndex < col.routes.length - 1 ? 6 : 0 })
                if (routeIndex < col.routes.length - 1) {
                  Row()
                    .width('100%')
                    .height(0.5)
                    .backgroundColor('#F2F2F7')
                }
              }, (route: string, routeIndex: number) => `${colIndex}-${routeIndex}`)
            }
            .width('100%')
            .padding(12)
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .height(220)
          .scrollable(ScrollDirection.Vertical)
          if (colIndex < columns.length - 1) {
            Row()
              .width(1)
              .height('100%')
              .backgroundColor('#F2F2F7')
          }
        }, (col: RouteColumn, colIndex: number) => colIndex.toString())
      }
      .alignItems(VerticalAlign.Top)
    }
    .width(320)
    .height(220)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .shadow({
      radius: 16,
      color: 'rgba(0, 0, 0, 0.2)',
      offsetY: 4
    })
    .clip(true)
  }
  .position({ x: position.x, y: position.y })
  .translate({ x: typeof position.x === 'string' && position.x === '100%' ? -340 : 0, y: 0 })
  .zIndex(101)
}

/**
 * 构建完整的菜单弹窗（包含遮罩层和菜单）
 * @param menuItems 菜单项数组
 * @param position 菜单位置
 * @param onDismiss 菜单关闭回调
 */
@Builder
export function buildMenuPopup(
  menuItems: MenuItem[],
  position: MenuPosition = { x: '100%', y: 56 },
  onDismiss: () => void
) {
  Stack() {
    // 透明遮罩层
    buildMenuOverlay(onDismiss)

    // 菜单内容
    buildExpandedMenu(menuItems, position, onDismiss)
  }
  .width('100%')
  .height('100%')
  .zIndex(100)
}
