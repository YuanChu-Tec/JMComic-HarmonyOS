import { router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { ApiService } from '../network/ApiService';

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
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = ApiService.getInstance();

  async aboutToAppear(): Promise<void> {
    // 加载已保存的登录凭据
    await this.loadSavedCredentials();
  }

  aboutToDisappear(): void {
    // 不要销毁单例，让其他组件继续使用
    // ApiService.destroyInstance();
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

      // 保存凭据
      await this.saveCredentials();

      // 登录成功，立即返回上一页（Index页面的个人中心会显示用户信息）
      console.info('[LoginPage] 登录成功');
      console.info('[LoginPage] session.uid=' + session.uid + ', username=' + session.username);
      console.info('[LoginPage] session.isLoggedIn=' + session.isLoggedIn);
      console.info('[LoginPage] apiService.isLoggedIn()=' + this.apiService.isLoggedIn());
      router.back();
    } catch (err) {
      let msg = (err as Error).message;
      if (msg.includes('账号或密码错误')) {
        this.errorMsg = '账号或密码错误，请检查后重试';
      } else if (msg.includes('网络连接超时')) {
        this.errorMsg = '网络连接超时，请检查网络后重试';
      } else {
        this.errorMsg = msg || '登录失败，请稍后重试';
      }
    } finally {
      this.isLoading = false;
    }
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
            .fontColor($r('app.color.text_primary'))
        }
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .onClick(() => this.onBack())

        Text('账号')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        // 占位保持平衡
        Row().width(40).height(40)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor($r('app.color.bg_card'))

      Divider().height(1).color($r('app.color.divider'))

      // ── 登录表单 ──
      Column() {
        // Logo / 标题
        Text('JMComic')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
          .margin({ top: 40, bottom: 8 })

        Text('登录以使用完整功能')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ bottom: 32 })

        // 用户名输入
        TextInput({ placeholder: '用户名/邮箱', text: this.username })
          .width('85%')
          .height(48)
          .fontSize(15)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(10)
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => this.username = value)

        // 密码输入
        TextInput({ placeholder: '密码', text: this.password })
          .width('85%')
          .height(48)
          .fontSize(15)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(10)
          .padding({ left: 16, right: 16 })
          .type(InputType.Password)
          .onChange((value: string) => this.password = value)
          .margin({ top: 12 })

        // 记住密码
        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.savePassword })
            .selectedColor($r('app.color.brand'))
            .onChange((checked: boolean) => this.savePassword = checked)

          Text('记住密码')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: 8 })
        }
        .width('85%')
        .margin({ top: 12 })
        .justifyContent(FlexAlign.Start)

        // 错误消息
        if (this.errorMsg) {
          Text(this.errorMsg)
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .margin({ top: 12 })
        }

        // 登录按钮
        Button({ type: ButtonType.Normal }) {
          if (this.isLoading) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('app.color.text_on_accent'))
          } else {
            Text('登  录')
              .fontSize(16)
              .fontColor($r('app.color.text_on_accent'))
          }
        }
        .width('85%')
        .height(48)
        .backgroundColor(this.isLoading ? $r('app.color.brand_disabled') : $r('app.color.brand'))
        .borderRadius(24)
        .margin({ top: 24 })
        .onClick(() => this.onLogin())
        .enabled(!this.isLoading)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
