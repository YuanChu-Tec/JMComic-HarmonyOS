import { JmAlbumInfo } from "../models/Album";
import { ApiService } from "../network/ApiService";
import { router } from "@kit.ArkUI";

@Component
export struct JmAlbumCard {
  @Require isTablet: boolean = false;
  // 可选：指定卡片宽度（vp）。0 表示使用默认宽度（平板 150 / 手机 120）
  cardWidth: number = 0;
  // 可选：宽度铺满父容器（用于 Grid 的 1fr 列），封面按 3:4 自动计算高度
  fillWidth: boolean = false;
  @Require cardInfo: JmAlbumInfo = {
    id: 0,
    name: '',
    author: [],
    image: '',
    description: '',
    category: ''
  };
  apiService: ApiService = ApiService.getInstance();

  /** 卡片宽度：铺满模式返回 100%，否则指定值优先，默认平板 150 / 手机 120 */
  private getCardWidth(): Length {
    if (this.fillWidth) {
      return '100%';
    }
    return this.cardWidth > 0 ? this.cardWidth : (this.isTablet ? 150 : 120);
  }

  build() {
    Column() {
      Image(this.apiService.buildCoverUrl(this.cardInfo.id))
        .width(this.getCardWidth())
        .aspectRatio(0.75) // 封面 3:4，宽度变化时高度自动跟随
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
        .backgroundColor($r('app.color.bg_secondary'))
        .onError((error) => {
          console.warn(`[JmAlbumCard] load cover failed: ${JSON.stringify(error)}`);
        })

      Text(this.cardInfo.name)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .maxLines(2)
        .lineHeight(16)
        .margin({ top: 6 })
        .width(this.getCardWidth())
        // 单行标题也占两行高度，保证同一行的卡片底部齐平
        .constraintSize({ minHeight: 32 })
    }
    // 顶部对齐：标题从图片下方第一行开始排，单行在第一行，两行占满两行。
    // 卡片高度由「封面（3:4）+ 6 间距 + 标题 minHeight 32」自然决定，各卡片等高。
    .width(this.getCardWidth())
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .onClick(() => this.onAlbumClick(this.cardInfo))
  }

  onAlbumClick(album: JmAlbumInfo): void {
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: { albumId: album.id, albumName: album.name }
    });
  }
}
