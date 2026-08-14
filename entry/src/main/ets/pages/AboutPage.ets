import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { ApiService } from '../network/ApiService';

/**
 * 防失联页面 — 展示官方及开发者联系方式
 */
@Entry
@Component
struct AboutPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  private apiService: ApiService = ApiService.getInstance();

  build() {
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
        .onClick(() => router.back())

        Text('防失联')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .margin({ right: 36 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 12, bottom: 12 })
      .backgroundColor($r('app.color.bg_card'))

      // ── 内容区 ──
      Scroll() {
        Column() {

          // ── 官方 ──
          Column() {
            Text('官方')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .margin({ bottom: 16 })

            Row() {
              Text('官网')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80)

              Text('18comic.vip')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .layoutWeight(1)
                .decoration({ type: TextDecorationType.Underline, color: $r('app.color.brand') })
                .onClick(() => this.openUrl('https://18comic.vip'))

              Button('复制')
                .fontSize(12)
                .fontColor($r('app.color.brand'))
                .backgroundColor($r('app.color.brand_bg'))
                .borderRadius(12)
                .height(28)
                .padding({ left: 10, right: 10 })
                .onClick(() => this.copyText('18comic.vip'))
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })

            Row() {
              Text('备用')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80)

              Text('18comic.org')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .layoutWeight(1)
                .decoration({ type: TextDecorationType.Underline, color: $r('app.color.brand') })
                .onClick(() => this.openUrl('https://18comic.org'))

              Button('复制')
                .fontSize(12)
                .fontColor($r('app.color.brand'))
                .backgroundColor($r('app.color.brand_bg'))
                .borderRadius(12)
                .height(28)
                .padding({ left: 10, right: 10 })
                .onClick(() => this.copyText('18comic.org'))
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })

            Row() {
              Text('纸飞机')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80)

              Text('https://t.me/JM_comic')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .layoutWeight(1)
                .decoration({ type: TextDecorationType.Underline, color: $r('app.color.brand') })
                .onClick(() => this.openUrl('https://t.me/JM_comic'))

              Button('复制')
                .fontSize(12)
                .fontColor($r('app.color.brand'))
                .backgroundColor($r('app.color.brand_bg'))
                .borderRadius(12)
                .height(28)
                .padding({ left: 10, right: 10 })
                .onClick(() => this.copyText('https://t.me/JM_comic'))
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
          }
          .width('100%')
          .padding(20)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ top: 20 })

          // ── 我的 ──
          Column() {
            Text('我的')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .margin({ bottom: 16 })

            Row() {
              Text('GitHub')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80)

              Text('https://github.com/YuanChu-Tec/JMComic-HarmonyOS')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .layoutWeight(1)
                .decoration({ type: TextDecorationType.Underline, color: $r('app.color.brand') })
                .onClick(() => this.openUrl('https://github.com/YuanChu-Tec/JMComic-HarmonyOS'))

              Button('复制')
                .fontSize(12)
                .fontColor($r('app.color.brand'))
                .backgroundColor($r('app.color.brand_bg'))
                .borderRadius(12)
                .height(28)
                .padding({ left: 10, right: 10 })
                .onClick(() => this.copyText('https://github.com/YuanChu-Tec/JMComic-HarmonyOS'))
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })

            Row() {
              Text('企鹅')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80)

              Text('1075753335')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Button('复制')
                .fontSize(12)
                .fontColor($r('app.color.brand'))
                .backgroundColor($r('app.color.brand_bg'))
                .borderRadius(12)
                .height(28)
                .padding({ left: 10, right: 10 })
                .onClick(() => this.copyText('1075753335'))
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })

            Row() {
              Text('纸飞机')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(80)

              Text('https://t.me/HMTGchat')
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .layoutWeight(1)
                .decoration({ type: TextDecorationType.Underline, color: $r('app.color.brand') })
                .onClick(() => this.openUrl('https://t.me/HMTGchat'))

              Button('复制')
                .fontSize(12)
                .fontColor($r('app.color.brand'))
                .backgroundColor($r('app.color.brand_bg'))
                .borderRadius(12)
                .height(28)
                .padding({ left: 10, right: 10 })
                .onClick(() => this.copyText('https://t.me/HMTGchat'))
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
          }
          .width('100%')
          .padding(20)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ top: 16 })

          Blank().height(32)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  openUrl(url: string): void {
    let context = getContext(this) as common.UIAbilityContext;
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browser'],
      uri: url
    };
    context.startAbility(want).catch((err: Error) => {
      console.error('[AboutPage] 打开链接失败: ' + err.message);
    });
  }

  copyText(text: string): void {
    let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    let systemPasteboard = pasteboard.getSystemPasteboard();
    systemPasteboard.setData(pasteData).then(() => {
      console.info('[AboutPage] 复制成功: ' + text);
    }).catch((err: Error) => {
      console.error('[AboutPage] 复制失败: ' + err.message);
    });
  }
}
