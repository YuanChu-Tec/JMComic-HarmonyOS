import { JmAlbumInfo } from "../models/Album";
import { ApiService } from "../network/ApiService";
import { router } from "@kit.ArkUI";

@Component
export struct JmAlbumCard {
  @Require isTablet: boolean = false;
  @Require cardInfo: JmAlbumInfo = {
    id: 0,
    name: '',
    author: [],
    image: '',
    description: '',
    category: ''
  };
  apiService: ApiService = ApiService.getInstance();

  build() {
    Column() {
      Image(this.apiService.buildCoverUrl(this.cardInfo.id))
        .width(this.isTablet ? 150 : 120)
        .height(this.isTablet ? 200 : 160)
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
        .width(this.isTablet ? 150 : 120)
    }
    // 固定卡片总高度 + 顶部对齐：标题从图片下方第一行开始排，
    // 单行自然落在第一行，两行占满两行；卡片总高固定，横滑时外框底部齐平。
    // 高度须容纳「图片 + 两行文字」(200/160 图 + 6 间距 + 2×16 文字)；
    // 标题仅 1 行时文字下方留白，卡片总高不变，对齐不受影响。
    .height(this.isTablet ? 246 : 206)
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
