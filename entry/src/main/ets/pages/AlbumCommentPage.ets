import { ApiService } from '../network/ApiService';
import { parseCommentRaw } from '../models/ComicAlbum';
import { CommentPageData, CommentInfoRaw } from '../models/dto/ApiDto';
import { CommentInfo } from '../models/ComicAlbum';
import { CacheManager } from '../common/CacheManager';
import { CommentItemComponent } from '../common/CommentItem';
import { navPop } from '../common/NavHelper';
import { CommentPageParams } from '../common/RouteParams';

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
  /** 下拉刷新指示器：用户显式拉取，与首屏 isLoading 分开 */
  @State isRefreshing: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private albumId: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private cache: CacheManager | null = null;
  /** 下拉刷新是否已有一轮在跑：Refresh 只管指示器，挡不住重复触发 */
  private isPulling: boolean = false;

  // NavDestination 标准入口：参数与数据加载移入 onReady（原 router.getParams 时代在 aboutToAppear）
  private async onPageReady(ctx: NavDestinationContext): Promise<void> {
    let params = ctx.pathInfo.param as CommentPageParams | null;
    if (params) {
      this.albumId = params.albumId;
      this.albumName = params.albumName || '评论';
    }
    this.cache = await CacheManager.getInstance();
    await this.loadComments();
  }

  private ownerId(): string {
    return this.albumId.toString();
  }

  /** 从库里读出已落库的评论页并拼接渲染，返回本地是否有内容 */
  private renderFromStore(): boolean {
    if (!this.cache) return false;
    let comments: CommentInfo[] = [];
    let total = 0;
    for (let page of this.cache.getCommentPages('manhua', this.ownerId())) {
      let entry = this.cache.loadCommentPage('manhua', this.ownerId(), page);
      if (entry === null) continue;
      total = Math.max(total, entry.total);
      let raws = JSON.parse(entry.data) as CommentInfoRaw[];
      for (let raw of raws) {
        comments.push(parseCommentRaw(raw));
      }
    }
    this.comments = comments;
    if (total > 0) {
      this.totalComments = total;
    }
    this.hasMore = this.comments.length < this.totalComments;
    return comments.length > 0;
  }

  /** Toast 统一走 UIContext 形态（开发规范 §5.5，禁模块级 promptAction 直呼） */
  private showToast(message: string, duration: number = 2000): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: duration });
  }

  aboutToDisappear(): void {
    // 不要销毁单例，让其他组件继续使用
    // this.apiService.destroy();
  }

  /**
   * 下拉刷新：该漫画的评论从第一页重拉。
   * 与首页同款：不清 this.comments，旧内容留在屏上，落库后由 renderFromStore 整体替换。
   * 旧分页整批作废，否则新第 1 页会和旧分页拼出重复条目（ForEach 用 comment.id 做 key）。
   */
  private async pullRefresh(): Promise<void> {
    if (this.isPulling) {
      this.isRefreshing = false;
      return;
    }
    this.isPulling = true;
    try {
      let data: CommentPageData = await this.apiService.getComments('manhua', this.ownerId(), 1);
      this.cache?.clearCommentPages('manhua', this.ownerId());
      if (this.cache) {
        this.cache.saveCommentPage('manhua', this.ownerId(), 1, JSON.stringify(data.list || []), data.total);
      }
      this.currentPage = 1;
      if (!this.renderFromStore()) {
        this.totalComments = data.total;
        this.comments = (data.list || []).map((raw) => parseCommentRaw(raw));
        this.hasMore = this.comments.length < this.totalComments;
      }
    } catch (err) {
      console.error('[AlbumCommentPage] pull refresh error:', JSON.stringify(err));
      this.showToast('刷新失败，已保留本地内容');
    } finally {
      this.isPulling = false;
      this.isRefreshing = false;
    }
  }

  async loadComments(): Promise<void> {
    this.loadFailed = false;
    // 1. 本地优先
    if (this.renderFromStore()) {
      this.isLoading = false;
      return;
    }
    // 2. 本地缺失才走网络
    this.isLoading = true;
    try {
      let page = this.currentPage;
      let data: CommentPageData = await this.apiService.getComments('manhua', this.ownerId(), page);
      // 3. 先落库，再从库读回来渲染
      if (this.cache) {
        this.cache.saveCommentPage('manhua', this.ownerId(), page, JSON.stringify(data.list || []), data.total);
      }
      if (!this.renderFromStore()) {
        // 落库不可用时兜底，保证页面有内容
        this.totalComments = data.total;
        this.comments = (data.list || []).map((raw) => parseCommentRaw(raw));
        this.hasMore = this.comments.length < this.totalComments;
      }
    } catch (err) {
      console.error('[AlbumCommentPage] loadComments error:', JSON.stringify(err));
      this.loadFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  async loadMoreComments(): Promise<void> {
    if (!this.hasMore || this.isLoadingMore) return;
    this.loadFailed = false;
    let page = this.currentPage + 1;
    // 1. 本地已有这一页：直接用
    if (this.cache && this.cache.loadCommentPage('manhua', this.ownerId(), page) !== null) {
      this.currentPage = page;
      this.renderFromStore();
      return;
    }
    // 2. 本地缺失才走网络
    this.isLoadingMore = true;
    try {
      let data: CommentPageData = await this.apiService.getComments('manhua', this.ownerId(), page);
      if (this.cache) {
        this.cache.saveCommentPage('manhua', this.ownerId(), page, JSON.stringify(data.list || []), data.total);
      }
      this.currentPage = page;
      if (!this.renderFromStore()) {
        this.comments = this.comments.concat((data.list || []).map((raw) => parseCommentRaw(raw)));
        this.hasMore = this.comments.length < this.totalComments;
      }
    } catch (err) {
      console.error('[AlbumCommentPage] loadMoreComments error:', JSON.stringify(err));
      this.loadFailed = true;
    } finally {
      this.isLoadingMore = false;
    }
  }

  async onSendComment(): Promise<void> {
    if (!this.sendText.trim()) return;
    if (!this.apiService.isLoggedIn()) {
      try {
        this.showToast('请先登录后再评论');
      } catch (e) {
        console.error('[AlbumCommentPage] showToast error:', JSON.stringify(e));
      }
      return;
    }
    try {
      let msg = await this.apiService.sendComment(this.albumId.toString(), this.sendText.trim(), '');
      console.info('[AlbumCommentPage] sendComment ok, msg=' + msg);
      this.sendText = '';
      // 发送成功后作废本地评论页再重载，保证拿到新评论
      if (this.cache) {
        this.cache.clearCommentPages('manhua', this.ownerId());
      }
      this.currentPage = 1;
      await this.loadComments();
      try {
        this.showToast(msg || '评论成功');
      } catch (e) {
        console.error('[AlbumCommentPage] showToast error:', JSON.stringify(e));
      }
    } catch (err) {
      let errMsg = (err as Error).message || '评论失败';
      console.error('[AlbumCommentPage] sendComment error:', JSON.stringify(err));
      try {
        this.showToast(errMsg);
      } catch (e) {
        // ignore
      }
    }
  }

  async handleSendReply(commentId: string, albumId: string, text: string): Promise<void> {
    if (!this.apiService.isLoggedIn()) {
      try {
        this.showToast('请先登录后再回复');
      } catch (e) {
        console.error('[AlbumCommentPage] showToast error:', JSON.stringify(e));
      }
      return;
    }
    try {
      let msg = await this.apiService.sendComment(this.albumId.toString(), text, commentId);
      // 回复成功后作废本地评论页再重载
      if (this.cache) {
        this.cache.clearCommentPages('manhua', this.ownerId());
      }
      this.currentPage = 1;
      await this.loadComments();
      try {
        this.showToast(msg || '回复成功', 1500);
      } catch (e) {
        // ignore
      }
    } catch (err) {
      console.error('[AlbumCommentPage] 回复失败:', JSON.stringify(err));
      try {
        this.showToast('回复失败');
      } catch (e) {
        // ignore
      }
    }
  }

  onBack(): void {
    navPop();
  }

  build() {
    NavDestination() {
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
          Refresh({ refreshing: $$this.isRefreshing }) {
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
            // 评论不足一屏时撑满视口并顶部对齐：否则 Scroll 会把矮内容垂直居中
            .constraintSize({ minHeight: '100%' })
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
          .onRefreshing(() => {
            this.pullRefresh();
          })
          .layoutWeight(1)
          .width('100%')
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

          Stack() {
            Text('发送')
              .fontSize(15)
              .fontColor($r('app.color.brand'))
              .fontWeight(FontWeight.Medium)
          }
          .width(40)
          .height(40)
          .onClick(() => this.onSendComment())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomSafeHeight + 28 })
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // ── 顶部导航栏 ──
      Row() {
        // 返回：40×40 标准点击体（裸 SymbolGlyph 字形宽仅约 13vp，不达 24vp 规范）
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
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
      .padding({ left: 12, right: 12, top: this.topSafeHeight + 4, bottom: 4 })
      .backgroundColor($r('app.color.header_bg'))
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.onPageReady(ctx);
    })
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function AlbumCommentPageBuilder() {
  AlbumCommentPage();
}
