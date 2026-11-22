import { ApiService } from '../network/ApiService';
import { AccountManager, SavedAccount } from '../common/AccountManager';
import { navPop, navPush } from '../common/NavHelper';

/**
 * 账号管理页面
 *
 * 展示已保存账号列表（当前账号标记「当前」），支持：
 * - 切换账号：点击其他账号，用保存的凭据重新登录
 * - 添加账号：跳转登录页，登录成功后自动登记
 * - 退出登录：移除当前账号并清空会话
 */
@Component
struct AccountManagePage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('activeUsername') @Watch('onActiveUserChanged') activeUsername: string = '';
  @State accounts: SavedAccount[] = [];
  @State switchingUsername: string = '';
  private accountManager: AccountManager = AccountManager.getInstance();
  private apiService: ApiService = ApiService.getInstance();

  aboutToAppear(): void {
    this.reloadAccounts();
  }

  /** 活跃账号变化（添加/切换账号）时刷新列表 */
  onActiveUserChanged(): void {
    this.reloadAccounts();
  }

  reloadAccounts(): void {
    this.accounts = this.accountManager.getAccounts();
  }

  private displayName(account: SavedAccount): string {
    return account.nickname ? account.nickname : account.username;
  }

  private buildAvatarUrl(photo: string): string {
    if (!photo) return '';
    let domain = this.apiService.getImageDomain();
    return `https://${domain}/media/users/${photo}`;
  }

  /** 确认弹窗（统一走 UIContext 形态）：返回是否点击了确认键 */
  private async confirmDialog(title: string, message: string, confirmText: string): Promise<boolean> {
    try {
      let result = await this.getUIContext().getPromptAction().showDialog({
        title: title,
        message: message,
        buttons: [
          { text: '取消', color: '#999999' },
          { text: confirmText, color: '#FF5A5F' }
        ]
      });
      return result.index === 1;
    } catch (err) {
      // 返回键/点击遮罩取消弹窗视为未确认
      console.warn('[AccountManagePage] dialog dismissed:', JSON.stringify(err));
      return false;
    }
  }

  onAddAccount(): void {
    if (this.switchingUsername) return;
    navPush('LoginPage');
  }

  async onAccountClick(account: SavedAccount): Promise<void> {
    if (this.switchingUsername) return;
    if (account.username === this.activeUsername) return;

    if (!account.password) {
      this.getUIContext().getPromptAction().showToast({ message: '该账号未保存密码，请通过添加账号重新登录', duration: 2000 });
      return;
    }

    let confirmed = await this.confirmDialog('切换账号', `确定切换到「${this.displayName(account)}」吗？`, '切换');
    if (!confirmed) return;

    this.switchingUsername = account.username;
    try {
      await this.accountManager.switchTo(account.username);
      this.getUIContext().getPromptAction().showToast({ message: '已切换到 ' + this.displayName(account), duration: 2000 });
      navPop();
    } catch (err) {
      let msg = (err as Error).message || '请稍后重试';
      this.getUIContext().getPromptAction().showToast({ message: '切换失败：' + msg, duration: 2000 });
    } finally {
      this.switchingUsername = '';
    }
  }

  async onLogoutClick(): Promise<void> {
    if (this.switchingUsername) return;

    let active = this.accountManager.getActiveAccount();
    let message = active ? `退出后「${this.displayName(active)}」将从账号列表移除，确定退出吗？` : '确定退出当前账号吗？';
    let confirmed = await this.confirmDialog('退出登录', message, '退出');
    if (!confirmed) return;

    try {
      await this.accountManager.logoutCurrent();
      this.getUIContext().getPromptAction().showToast({ message: '已退出登录', duration: 2000 });
      navPop();
    } catch (err) {
      console.error('[AccountManagePage] logout error:', JSON.stringify(err));
      this.getUIContext().getPromptAction().showToast({ message: '退出失败，请重试', duration: 2000 });
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
          .onClick(() => navPop())

          Text('账号管理')
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
            // ── 已保存账号列表 ──
            Column() {
              if (this.accounts.length === 0) {
                Text('暂无已保存账号')
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
                  .padding({ top: 20, bottom: 20 })
              }
              ForEach(this.accounts, (account: SavedAccount, idx: number) => {
                if (idx > 0) {
                  Divider()
                    .height(1)
                    .color($r('app.color.divider'))
                }
                Row() {
                  if (this.buildAvatarUrl(account.photo)) {
                    Image(this.buildAvatarUrl(account.photo))
                      .width(44)
                      .height(44)
                      .borderRadius(22)
                      .objectFit(ImageFit.Cover)
                      .backgroundColor($r('app.color.bg_secondary'))
                  } else {
                    Image($r('app.media.ic_default_avatar'))
                      .width(44)
                      .height(44)
                      .borderRadius(22)
                      .objectFit(ImageFit.Cover)
                      .backgroundColor($r('app.color.bg_secondary'))
                  }

                  Column() {
                    Text(this.displayName(account))
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    if (!account.password) {
                      Text('未保存密码，无法快速切换')
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ top: 2 })
                    } else if (account.level > 0) {
                      Text(`Lv.${account.level} · ${account.levelName}`)
                        .fontSize(12)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ top: 2 })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .margin({ left: 12 })
                  .layoutWeight(1)

                  if (account.username === this.activeUsername) {
                    Text('当前')
                      .fontSize(12)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .backgroundColor($r('app.color.brand_bg'))
                      .borderRadius(10)
                  } else if (this.switchingUsername === account.username) {
                    LoadingProgress()
                      .width(20)
                      .height(20)
                      .color($r('app.color.brand'))
                  }

                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([$r('app.color.text_disabled')])
                    .margin({ left: 8 })
                    .visibility(account.username === this.activeUsername ? Visibility.None : Visibility.Visible)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .onClick(() => this.onAccountClick(account))
              }, (account: SavedAccount) => account.username)
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)

            // ── 添加账号 ──
            Row() {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(20)
                .fontColor([$r('app.color.text_secondary')])

              Text('添加账号')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .margin({ left: 10 })
                .layoutWeight(1)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(16)
                .fontColor([$r('app.color.text_disabled')])
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
            .margin({ top: 12 })
            .onClick(() => this.onAddAccount())

            // ── 退出登录 ──
            Button({ type: ButtonType.Normal }) {
              Text('退出登录')
                .fontSize(15)
                .fontColor($r('app.color.brand'))
            }
            .backgroundColor($r('app.color.brand_bg'))
            .borderRadius(22)
            .width('100%')
            .height(44)
            .margin({ top: 24 })
            .onClick(() => this.onLogoutClick())
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
export function AccountManagePageBuilder() {
  AccountManagePage();
}
