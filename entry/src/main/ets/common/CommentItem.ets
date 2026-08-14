import { ApiService } from '../network/ApiService';
import {
  CommentInfo,
} from '../models/Album';
import { router } from '@kit.ArkUI';

@Component
export struct CommentItemComponent {
  comment: CommentInfo = {
    id: '', uid: '', name: '', level: '', title: '', date: '', content: '',
    headUrl: '', like: 0, linkBookId: '', linkBookName: '', subComments: [],
  };
  index: number = 0;
  onSendReply: (commentId: string, albumId: string, text: string) => void = () => {};
  @State replyText: string = '';
  linkClickable: boolean = true;  // 关联漫画是否可点击
  private apiService: ApiService = ApiService.getInstance();

  buildHeadUrl(): string {
    if (!this.comment.headUrl) {
      return '';
    }
    let domain = this.apiService.getImageDomain();
    return `https://${domain}${this.comment.headUrl}`;
  }

  // 点击关联漫画跳转
  onLinkClick(): void {
    if (this.comment.linkBookId) {
      router.pushUrl({
        url: 'pages/AlbumDetailPage',
        params: { albumId: parseInt(this.comment.linkBookId) || 0, albumName: this.comment.linkBookName }
      });
    }
  }

  doSendReply(): void {
    if (!this.replyText.trim()) return;
    this.onSendReply(this.comment.id, this.comment.linkBookId, this.replyText.trim());
    this.replyText = '';
  }

  build() {
    Column() {
      // ── 主评论行 ──
      Row() {
        // ── 左侧：头像 + 等级 ──
        Column() {
          // 头像
          if (this.buildHeadUrl()) {
            Image(this.buildHeadUrl())
              .width(48)
              .height(48)
              .borderRadius(24)
              .objectFit(ImageFit.Cover)
              .backgroundColor($r('app.color.bg_secondary'))
          } else {
            Image($r('app.media.ic_default_avatar'))
              .width(48)
              .height(48)
              .borderRadius(24)
              .objectFit(ImageFit.Cover)
              .backgroundColor($r('app.color.bg_secondary'))
          }

          // 等级
          Text(this.comment.level ? `Lv${this.comment.level}` : '')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .width(56)
            .textAlign(TextAlign.Center)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Center)
        .width(60)

        // ── 右侧：用户名 + 称号 + 内容 + 操作 + 关联漫画 ──
        Column() {
          // 用户名 + 称号 + 日期（右上角）
          Row() {
            Text(this.comment.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.comment.title) {
              Text(`·${this.comment.title}`)
                .fontSize(14)
                .fontColor($r('app.color.text_accent_warm'))
            }

            Blank()

            // 日期显示在右上角
            Text(this.comment.date ? this.comment.date.substring(0, 10) : '')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')

          // 评论内容
          Text(this.comment.content)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .lineHeight(22)
            .margin({ top: 6 })
            .width('100%')

          // 点赞 + 关联漫画（右下角）
          Row() {
            Row() {
              SymbolGlyph($r('sys.symbol.heart'))
                .fontSize(14)
                .fontColor([$r('app.color.text_tertiary')])
              Text(`${this.comment.like}`)
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ left: 3 })
            }

            Blank()

            // 关联漫画显示在右下角
            if (this.comment.linkBookId && this.comment.linkBookName) {
              Text(this.comment.linkBookName)
                .fontSize(10)
                .fontColor($r('app.color.brand'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(this.linkClickable ? () => this.onLinkClick() : undefined)
            }
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // ── 子评论区域（在头像和右侧信息下方） ──
      if (this.comment.subComments && this.comment.subComments.length > 0) {
        Column() {
          ForEach(this.comment.subComments, (sub: CommentInfo, subIdx: number) => {
            // 子评论：与主评论布局一致，左侧增加空位
            Row() {
              // ── 左侧：头像 + 等级 ──
              Column() {
                if (sub.headUrl) {
                  Image(`https://${this.apiService.getImageDomain()}${sub.headUrl}`)
                    .width(32)
                    .height(32)
                    .borderRadius(16)
                    .objectFit(ImageFit.Cover)
                    .backgroundColor($r('app.color.bg_secondary'))
                } else {
                  Image($r('app.media.ic_default_avatar'))
                    .width(32)
                    .height(32)
                    .borderRadius(16)
                    .objectFit(ImageFit.Cover)
                    .backgroundColor($r('app.color.bg_secondary'))
                }

                // 等级
                if (sub.level) {
                  Text(`Lv${sub.level}`)
                    .fontSize(10)
                    .fontColor($r('app.color.brand'))
                    .margin({ top: 2 })
                }
              }
              .alignItems(HorizontalAlign.Center)
              .width(40)

              // ── 右侧：用户名 + 称号 + 内容 ──
              Column() {
                // 用户名 + 称号 + 日期（右上角）
                Row() {
                  Text(sub.name)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (sub.title) {
                    Text(`·${sub.title}`)
                      .fontSize(13)
                      .fontColor($r('app.color.text_accent_warm'))
                  }

                  Blank()

                  // 日期显示在右上角
                  Text(sub.date ? sub.date.substring(0, 10) : '')
                    .fontSize(10)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .width('100%')

                // 评论内容
                Text(sub.content)
                  .fontSize(13)
                  .fontColor($r('app.color.text_gray'))
                  .lineHeight(20)
                  .margin({ top: 4 })
                  .width('100%')
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                // 点赞
                Row() {
                  if (sub.like > 0) {
                    Row() {
                      SymbolGlyph($r('sys.symbol.heart'))
                        .fontSize(12)
                        .fontColor([$r('app.color.text_tertiary')])
                      Text(`${sub.like}`)
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ left: 2 })
                    }
                  }
                }
                .width('100%')
                .margin({ top: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 6 })
            }
            .width('100%')
            .padding(10)
            .backgroundColor($r('app.color.bg_page_alt'))
            .borderRadius(6)
            .margin({ top: 6 })
            .alignItems(VerticalAlign.Top)
          }, (sub: CommentInfo) => sub.id)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: 6 })
        //.padding({ left: 20 })  // 左侧增加空位，形成层级
      }

      // ── 回复输入框 ──
      Row() {
        TextInput({ placeholder: '给个回应', text: this.replyText })
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(18)
          .padding({ left: 14, right: 14 })
          .onChange((value: string) => { this.replyText = value; })

        Text('发送')
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .padding({ left: 10, right: 4 })
          .onClick(() => this.doSendReply())
      }
      .width('100%')
      .padding({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(8)
  }
}
