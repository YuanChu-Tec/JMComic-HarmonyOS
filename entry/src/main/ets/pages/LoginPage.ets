import { router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { ApiService } from '../network/ApiService';
import { UserSession } from '../models/Album';

const PREF_NAME = 'JMComicUser';

/**
 * 登录页面
 * 支持用户名+密码登录，自动保存凭据
 */
@Entry
@Component
struct LoginPage {
  @State username: string = '';
  @State password: string = '';
  @State isLoading: boolean = false;
  @State errorMsg: string = '';
  @State savePassword: boolean = true;
  @State userSession: UserSession | null = null;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = new ApiService();

  async aboutToAppear(): Promise<void> {
    // 加载已保存的登录凭据
    await this.loadSavedCredentials();
    // 检查当前登录状态
    this.userSession = this.apiService.getUserSession();
  }

  aboutToDisappear(): void {
    this.apiService.destroy();
  }

  async loadSavedCredentials(): Promise<void> {
    try {
      let prefs = await preferences.getPreferences(getContext(), PREF_NAME);
      let savedUser = prefs.getSync('username', '') as string;
      let savedPass = prefs.getSync('password', '') as string;
      let savedSave = prefs.getSync('savePassword', true) as boolean;
      if (savedUser) {
        this.username = savedUser;
      }
      if (savedPass) {
        this.password = savedPass;
      }
      this.savePassword = savedSave;
    } catch (err) {
      // preferences not available, use defaults
    }
  }

  async saveCredentials(): Promise<void> {
    try {
      let prefs = await preferences.getPreferences(getContext(), PREF_NAME);
      prefs.putSync('username', this.username);
      if (this.savePassword) {
        prefs.putSync('password', this.password);
      } else {
        prefs.putSync('password', '');
      }
      prefs.putSync('savePassword', this.savePassword);
      prefs.flushSync();
    } catch (err) {
      console.error('saveCredentials error:', JSON.stringify(err));
    }
  }

  async onLogin(): Promise<void> {
    if (!this.username.trim()) {
      this.errorMsg = '请输入用户名';
      return;
    }
    if (!this.password.trim()) {
      this.errorMsg = '请输入密码';
      return;
    }

    this.isLoading = true;
    this.errorMsg = '';

    try {
      let session = await this.apiService.login(this.username.trim(), this.password);
      this.userSession = session;

      // 保存凭据
      await this.saveCredentials();

      // 登录成功，返回上一页
      setTimeout(() => {
        router.back();
      }, 500);
    } catch (err) {
      let msg = (err as Error).message;
      if (msg.includes('登录失败') || msg.includes('password') || msg.includes('username')) {
        this.errorMsg = '用户名或密码错误';
      } else {
        this.errorMsg = msg || '登录失败，请稍后重试';
      }
    } finally {
      this.isLoading = false;
    }
  }

  onLogout(): void {
    this.apiService.logout();
    this.userSession = null;
    // 不清除用户名，方便下次登录
  }

  onBack(): void {
    router.back();
  }

  build() {
    Column() {
      // ── 顶部标题栏 ──
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('←')
            .fontSize(20)
            .fontColor('#333333')
        }
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .onClick(() => this.onBack())

        Text('账号')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        // 占位保持平衡
        Row().width(40).height(40)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor('#FFFFFF')

      Divider().height(1).color('#F0F0F0')

      // ── 内容区 ──
      if (this.userSession !== null && this.userSession.isLoggedIn) {
        // 已登录状态
        Column() {
          // 用户头像占位
          Column() {
            Text(this.userSession.username.charAt(0).toUpperCase())
              .fontSize(36)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
          }
          .width(80)
          .height(80)
          .borderRadius(40)
          .backgroundColor('#FF5A5F')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 32, bottom: 12 })

          Text(this.userSession.username)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')

          Text(`Lv.${this.userSession.level} · ${this.userSession.levelName}`)
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 4 })

          // 统计卡片
          Row() {
            this.StatItem('金币', this.userSession.coin.toString())
            this.StatItem('收藏', `${this.userSession.albumFavorites}/${this.userSession.albumFavoritesMax}`)
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 20, bottom: 20 })
          .justifyContent(FlexAlign.SpaceEvenly)

          // 退出按钮
          Button({ type: ButtonType.Normal }) {
            Text('退出登录')
              .fontSize(15)
              .fontColor('#FF5A5F')
          }
          .backgroundColor('#FFF0F0')
          .borderRadius(22)
          .width(200)
          .height(44)
          .margin({ top: 24 })
          .onClick(() => this.onLogout())
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      } else {
        // 未登录 - 登录表单
        Column() {
          // Logo / 标题
          Text('JMComic')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF5A5F')
            .margin({ top: 40, bottom: 8 })

          Text('登录以使用完整功能')
            .fontSize(14)
            .fontColor('#999999')
            .margin({ bottom: 32 })

          // 用户名输入
          TextInput({ placeholder: '用户名/邮箱', text: this.username })
            .width('85%')
            .height(48)
            .fontSize(15)
            .backgroundColor('#F5F5F5')
            .borderRadius(10)
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => this.username = value)

          // 密码输入
          TextInput({ placeholder: '密码', text: this.password })
            .width('85%')
            .height(48)
            .fontSize(15)
            .backgroundColor('#F5F5F5')
            .borderRadius(10)
            .padding({ left: 16, right: 16 })
            .type(InputType.Password)
            .onChange((value: string) => this.password = value)
            .margin({ top: 12 })

          // 记住密码
          Row() {
            Toggle({ type: ToggleType.Switch, isOn: this.savePassword })
              .selectedColor('#FF5A5F')
              .onChange((checked: boolean) => this.savePassword = checked)

            Text('记住密码')
              .fontSize(13)
              .fontColor('#999999')
              .margin({ left: 8 })
          }
          .width('85%')
          .margin({ top: 12 })
          .justifyContent(FlexAlign.Start)

          // 错误消息
          if (this.errorMsg) {
            Text(this.errorMsg)
              .fontSize(13)
              .fontColor('#FF5A5F')
              .margin({ top: 12 })
          }

          // 登录按钮
          Button({ type: ButtonType.Normal }) {
            if (this.isLoading) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color('#FFFFFF')
            } else {
              Text('登  录')
                .fontSize(16)
                .fontColor('#FFFFFF')
            }
          }
          .width('85%')
          .height(48)
          .backgroundColor(this.isLoading ? '#FF9E9E' : '#FF5A5F')
          .borderRadius(24)
          .margin({ top: 24 })
          .onClick(() => this.onLogin())
          .enabled(!this.isLoading)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  StatItem(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#333333')
      Text(label)
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Center)
  }
}
