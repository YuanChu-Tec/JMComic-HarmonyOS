import { router, promptAction } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import {
  CommentInfo,
  CommentPageData,
  parseCommentRaw,
} from '../models/Album';
import { CommentItemComponent } from '../common/CommentItem';

interface CommentPageParams {
  albumId: number;
  albumName: string;
}

@Entry
@Component
struct AlbumCommentPage {
  @State comments: CommentInfo[] = [];
  @State isLoading: boolean = true;
  @State isLoadingMore: boolean = false;
  @State currentPage: number = 1;
  @State totalComments: number = 0;
  @State hasMore: boolean = true;
  @State sendText: string = '';
  @State albumName: string = '评论';
  @State loadFailed: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private albumId: number = 0;
  private apiService: ApiService = ApiService.getInstance();

  aboutToAppear(): void {
    let params = router.getParams() as CommentPageParams;
    if (params) {
      this.albumId = params.albumId;
      this.albumName = params.albumName || '评论';
    }
    this.loadComments();
  }

  aboutToDisappear(): void {
    // 不要销毁单例，让其他组件继续使用
    // this.apiService.destroy();
  }

  async loadComments(): Promise<void> {
    this.isLoading = true;
    this.loadFailed = false;
    try {
      let data: CommentPageData = await this.apiService.getComments('manhua', this.albumId.toString(), this.currentPage);
      this.totalComments = data.total;
      this.comments = (data.list || []).map((raw) => parseCommentRaw(raw));
      this.hasMore = this.comments.length < this.totalComments;
    } catch (err) {
      console.error('[AlbumCommentPage] loadComments error:', JSON.stringify(err));
      this.loadFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  async loadMoreComments(): Promise<void> {
    if (!this.hasMore || this.isLoadingMore) return;
    this.isLoadingMore = true;
    this.loadFailed = false;
    this.currentPage++;
    try {
      let data: CommentPageData = await this.apiService.getComments('manhua', this.albumId.toString(), this.currentPage);
      let newComments = (data.list || []).map((raw) => parseCommentRaw(raw));
      this.comments = this.comments.concat(newComments);
      this.hasMore = this.comments.length < this.totalComments;
    } catch (err) {
      console.error('[AlbumCommentPage] loadMoreComments error:', JSON.stringify(err));
      this.currentPage--;
      this.loadFailed = true;
    } finally {
      this.isLoadingMore = false;
    }
  }

  async onSendComment(): Promise<void> {
    if (!this.sendText.trim()) return;
    if (!this.apiService.isLoggedIn()) {
      try {
        await promptAction.showToast({ message: '请先登录后再评论', duration: 2000 });
      } catch (e) {
        console.error('[AlbumCommentPage] showToast error:', JSON.stringify(e));
      }
      return;
    }
    try {
      let msg = await this.apiService.sendComment(this.albumId.toString(), this.sendText.trim(), '');
      console.info('[AlbumCommentPage] sendComment ok, msg=' + msg);
      this.sendText = '';
      // 发送成功后刷新评论
      this.currentPage = 1;
      await this.loadComments();
      try {
        await promptAction.showToast({ message: msg || '评论成功', duration: 2000 });
      } catch (e) {
        console.error('[AlbumCommentPage] showToast error:', JSON.stringify(e));
      }
    } catch (err) {
      let errMsg = (err as Error).message || '评论失败';
      console.error('[AlbumCommentPage] sendComment error:', JSON.stringify(err));
      try {
        await promptAction.showToast({ message: errMsg, duration: 2000 });
      } catch (e) {
        // ignore
      }
    }
  }

  async handleSendReply(commentId: string, albumId: string, text: string): Promise<void> {
    if (!this.apiService.isLoggedIn()) {
      try {
        await promptAction.showToast({ message: '请先登录后再回复', duration: 2000 });
      } catch (e) {
        console.error('[AlbumCommentPage] showToast error:', JSON.stringify(e));
      }
      return;
    }
    try {
      let msg = await this.apiService.sendComment(this.albumId.toString(), text, commentId);
      // 回复成功后刷新
      this.currentPage = 1;
      await this.loadComments();
      try {
        await promptAction.showToast({ message: msg || '回复成功', duration: 1500 });
      } catch (e) {
        // ignore
      }
    } catch (err) {
      console.error('[AlbumCommentPage] 回复失败:', JSON.stringify(err));
      try {
        await promptAction.showToast({ message: '回复失败', duration: 2000 });
      } catch (e) {
        // ignore
      }
    }
  }

  onBack(): void {
    router.back();
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.brand'))
            Text('加载中...')
              .fontSize(14)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.comments.length === 0 && this.loadFailed) {
          Column() {
            Text('加载失败')
              .fontSize(16)
              .fontColor($r('app.color.text_tertiary'))
            Button('重新加载')
              .fontSize(14)
              .fontColor($r('app.color.text_on_accent'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(18)
              .padding({ left: 24, right: 24 })
              .height(36)
              .margin({ top: 16 })
              .onClick(() => this.loadComments())
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.comments.length === 0) {
          Column() {
            Text('暂无评论')
              .fontSize(16)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              ForEach(this.comments, (comment: CommentInfo, index: number) => {
                CommentItemComponent({
                  comment: comment,
                  index: index + 1,
                  onSendReply: this.handleSendReply,
                  linkClickable: false,  // 评论页关联漫画不可点击
                })
                  .margin({ top: 8, left: 12, right: 12 })
              }, (comment: CommentInfo) => comment.id)

              // 加载更多 / 没有更多
              if (this.isLoadingMore) {
                Row() {
                  LoadingProgress()
                    .width(24)
                    .height(24)
                    .color($r('app.color.brand'))
                  Text('加载更多...')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 16, bottom: 16 })
              } else if (this.loadFailed) {
                Row() {
                  Text('加载失败')
                    .fontSize(13)
                    .fontColor($r('app.color.text_tertiary'))
                  Text('重新加载')
                    .fontSize(13)
                    .fontColor($r('app.color.brand'))
                    .margin({ left: 12 })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 16, bottom: 16 })
                .onClick(() => this.loadMoreComments())
              } else if (this.hasMore) {
                Text('上拉加载更多')
                  .fontSize(13)
                  .fontColor($r('app.color.text_disabled'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 16, bottom: 16 })
              } else {
                Text('没有更多了')
                  .fontSize(13)
                  .fontColor($r('app.color.text_disabled'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 16, bottom: 16 })
              }
            }
            .width('100%')
            .padding({ top: this.topSafeHeight + 56 })  // 避免被导航栏遮挡
            .justifyContent(FlexAlign.Start)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .onReachEnd(() => {
            if (!this.isLoadingMore && this.hasMore) {
              this.loadMoreComments();
            }
          })
        }

        // ── 底部评论输入栏 ──
        Row() {
          TextInput({ placeholder: '写评论...', text: this.sendText })
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .backgroundColor($r('app.color.bg_page'))
            .borderRadius(20)
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => { this.sendText = value; })

          Text('发送')
            .fontSize(15)
            .fontColor($r('app.color.brand'))
            .fontWeight(FontWeight.Medium)
            .padding({ left: 12, right: 8 })
            .onClick(() => this.onSendComment())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomSafeHeight + 8 })
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // ── 顶部导航栏 ──
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.text_primary')])
          .onClick(() => this.onBack())

        Column() {
          Text(this.albumName)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(`${this.totalComments} 条评论`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 1 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })

        // 占位保持对称
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([Color.Transparent])
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 12, right: 12, top: this.topSafeHeight + 20, bottom: 4 })
      .backgroundColor($r('app.color.header_bg'))
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
