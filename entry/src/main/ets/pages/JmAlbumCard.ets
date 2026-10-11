import { hilog } from "@kit.PerformanceAnalysisKit";
import { JmAlbumInfo } from "../models/Album";
import { ApiService } from "../network/ApiService";
import { router } from "@kit.ArkUI";

const TAG: string = 'JmAlbumCard';

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

  constructor(isTablet: boolean, info: JmAlbumInfo) {
    super();
    this.isTablet = isTablet;
    this.cardInfo = info;
  }

  build() {
    Column() {
      Image(this.apiService.buildCoverUrl(this.cardInfo.id))
        .width(this.isTablet ? 150 : 120)
        .height(this.isTablet ? 200 : 160)
        .objectFit(ImageFit.Fill)
        .borderRadius(8)
        .backgroundColor($r('app.color.bg_secondary'))
        .onError((error) => {
          hilog.warn(0, TAG, `err msg:${JSON.stringify(error)}`);
        })

      Text(this.cardInfo.name)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .maxLines(1)
        .lineHeight(16)
        .width(this.isTablet ? 150 : 120)
        .constraintSize({ maxHeight: 32 })
    }
    .height(this.isTablet ? 220 : 176)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .onClick(() => this.onAlbumClick(this.cardInfo))
  }

  onAlbumClick(album: JmAlbumInfo): void {
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: { albumId: this.id, albumName: album.name }
    });
  }
}