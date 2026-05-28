import { router } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import {
  JmAlbumDetail,
  JmPhotoInfo,
  PhotoViewModel,
  JmTagInfo,
  JmRelatedWork,
  AlbumViewModel,
  JmAlbumSeries,
  CategoryBean
} from '../models/Album';

interface RouterParams {
  albumId: number;
  albumName: string;
}

interface SeriesItem {
  id: number;
  name: string;
}

interface ChapterRouteInfo {
  photoId: string;
  photoName: string;
}

@Entry
@Component
struct AlbumDetailPage {
  @State album: JmAlbumDetail | null = null;
  @State chapters: PhotoViewModel[] = [];
  @State isLoading: boolean = true;
  @State albumName: string = '详情';
  @State isChapterExpanded: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private albumId: number = 0;
  private apiService: ApiService = new ApiService();

  aboutToAppear(): void {
    let params = router.getParams() as RouterParams;
    if (params) {
      this.albumId = params.albumId;
      this.albumName = params.albumName || '详情';
    }
    this.loadDetail();
  }

  async loadDetail(): Promise<void> {
    this.isLoading = true;
    try {
      let resp = await this.apiService.getAlbumDetail(this.albumId);

      if (resp.code === 200 && resp.data) {
        this.album = resp.data as JmAlbumDetail;
        if (this.album) {
          // series 包含章节列表，每项为 {id, name, sort}
          let series = this.album.series;
          if (series && series.length > 0) {
            this.chapters = series.map((ep: JmAlbumSeries, index: number) => {
              let vm = new PhotoViewModel();
              vm.id = typeof ep.id === 'number' ? ep.id : parseInt(ep.id) || 0;
              vm.photoId = ep.id?.toString() || '';
              vm.name = ep.name || '';
              vm.index = typeof ep.sort === 'number' ? ep.sort : parseInt(ep.sort) || (index + 1);
              vm.scrambleId = 0;
              return vm;
            });
          } else {
            // 单本漫画：无 series，用 albumId 作为唯一章节
            let vm = new PhotoViewModel();
            vm.id = this.albumId;
            vm.photoId = this.albumId.toString();
            vm.name = '第1话';
            vm.index = 1;
            vm.scrambleId = 0;
            this.chapters = [vm];
          }
          this.albumName = this.album.name;
        }
      }
    } catch (err) {
      console.error('loadDetail error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  onChapterClick(photo: PhotoViewModel): void {
    let chapters: ChapterRouteInfo[] = this.chapters.map((ch) => {
      return { photoId: ch.photoId, photoName: ch.name } as ChapterRouteInfo;
    });
    let currentIndex = this.chapters.findIndex(ch => ch.photoId === photo.photoId);
    router.pushUrl({
      url: 'pages/ImageViewerPage',
      params: {
        photoId: photo.photoId,
        photoName: photo.name,
        scrambleId: photo.scrambleId,
        albumId: this.albumId,
        albumName: this.albumName,
        chaptersStr: JSON.stringify(chapters),
        currentChapterIndex: currentIndex >= 0 ? currentIndex : 0
      }
    });
  }

  onBack(): void {
    router.back();
  }

  parseAuthorList(author: string | string[]): string[] {
    if (Array.isArray(author)) {
      return author;
    }
    return author ? [author] : [];
  }

  formatAuthor(author: string | string[]): string {
    if (Array.isArray(author)) {
      return author.join(', ');
    }
    return author || '';
  }

  build() {
    Stack() {
      // ── 全屏内容 ──
      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color('#FF5A5F')
          Text('加载中...')
            .fontSize(14)
            .fontColor('#999999')
            .margin({ top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.album) {
        Scroll() {
          Column() {
            // ── 顶部留白（避开浮层顶栏） ──
            Row().height(this.topSafeHeight + 48)

            // ── 基本信息区 ──
            Row() {
              // 封面
              Image(this.apiService.buildCoverUrl(this.album.id, ''))
                .width(120)
                .height(165)
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
                .backgroundColor('#F0F0F0')

              Column() {
                Text(this.album.name)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#333333')
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .lineHeight(24)

                Row() {
                  if (this.album.category && typeof this.album.category === 'object') {
                    Text((this.album.category as CategoryBean).title || '')
                      .fontSize(12)
                      .fontColor('#FF5A5F')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor('#FFF0F0')
                      .borderRadius(4)
                      .margin({ right: 8 })
                  }
                }
                .width('100%')
                .margin({ top: 8 })

                Row() {
                  Text(`👁 ${this.album.total_views}`)
                    .fontSize(12)
                    .fontColor('#999999')
                    .margin({ right: 16 })

                  Text(`📷 ${this.chapters.length}话`)
                    .fontSize(12)
                    .fontColor('#999999')
                    .margin({ right: 16 })

                  Text(`❤ ${this.album.likes}`)
                    .fontSize(12)
                    .fontColor('#999999')
                    .margin({ right: 16 })

                  Text(`💬 ${this.album.comment_total || 0}`)
                    .fontSize(12)
                    .fontColor('#999999')
                }
                .width('100%')
                .margin({ top: 8 })

                Text('禁漫车')
                  .fontSize(14)
                  .fontColor('#999999')
                Text(`JM${this.album.id}`)
                  .fontSize(14)
                  .fontColor('#666666')
              }
              .layoutWeight(1)
              .height(165)
              .margin({ left: 16 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding(16)

            // 描述
            if (this.album.description && this.album.description.length > 0) {
              Column() {
                Text('简介')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
                  .margin({ bottom: 8 })

                Text(this.album.description)
                  .fontSize(14)
                  .fontColor('#666666')
                  .lineHeight(22)
                  .maxLines(6)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 16 })
              .alignItems(HorizontalAlign.Start)
            }

            // 标签
            if (this.album.tags && this.album.tags.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.album.tags, (tag: string) => {
                  Text(tag)
                    .fontSize(12)
                    .fontColor('#FF5A5F')
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .backgroundColor('#FFF5F5')
                    .borderRadius(4)
                    .border({ width: 0.5, color: '#FFD4D4' })
                    .margin({ right: 8, bottom: 8 })
                    .onClick(() => {
                      if (tag) {
                        router.pushUrl({
                          url: 'pages/SearchPage',
                          params: { keyword: tag }
                        });
                      }
                    })
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 4 })
            }

            // 作者
            if (this.parseAuthorList(this.album?.author ?? '').length > 0) {
              Column() {
                Text('作者')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
                  .width('100%')
                  .margin({ bottom: 6 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.parseAuthorList(this.album?.author ?? ''), (name: string) => {
                    Text(name)
                      .fontSize(12)
                      .fontColor('#FF5A5F')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor('#FFF5F5')
                      .borderRadius(4)
                      .border({ width: 0.5, color: '#FFD4D4' })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (name) {
                          router.pushUrl({
                            url: 'pages/SearchPage',
                            params: { keyword: name }
                          });
                        }
                      })
                  }, (name: string) => name)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            }

            // 登场人物
            if (this.album.actors && this.album.actors.length > 0) {
              Column() {
                Text('登场人物')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
                  .width('100%')
                  .margin({ bottom: 6 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.album.actors, (actor: string) => {
                    Text(actor)
                      .fontSize(12)
                      .fontColor('#FF5A5F')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor('#FFF5F5')
                      .borderRadius(4)
                      .border({ width: 0.5, color: '#FFD4D4' })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (actor) {
                          router.pushUrl({
                            url: 'pages/SearchPage',
                            params: { keyword: actor }
                          });
                        }
                      })
                  }, (actor: string) => actor)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            }

            // 作品（该漫画所属的作品/IP）
            if (this.album.works && this.album.works.length > 0) {
              Column() {
                Text('作品')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
                  .width('100%')
                  .margin({ bottom: 6 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.album.works, (work: string) => {
                    Text(work)
                      .fontSize(12)
                      .fontColor('#FF5A5F')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor('#FFF5F5')
                      .borderRadius(4)
                      .border({ width: 0.5, color: '#FFD4D4' })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        if (work) {
                          router.pushUrl({
                            url: 'pages/SearchPage',
                            params: { keyword: work }
                          });
                        }
                      })
                  }, (work: string) => work)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            }

            // ── 开始阅读 + 评论 按钮 ──
            if (this.chapters.length > 0) {
              Row() {
                Button('开始阅读')
                  .layoutWeight(1)
                  .height(48)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#FF5A5F')
                  .borderRadius(24)
                  .onClick(() => this.onChapterClick(this.chapters[0]))

                Button('评论')
                  .height(48)
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FF5A5F')
                  .backgroundColor('#FFFFFF')
                  .borderRadius(24)
                  .border({ width: 1, color: '#FF5A5F' })
                  .padding({ left: 24, right: 24 })
                  .margin({ left: 12 })
                  .onClick(() => {
                    router.pushUrl({
                      url: 'pages/AlbumCommentPage',
                      params: { albumId: this.albumId, albumName: this.albumName }
                    });
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 16 })
            }

            // ── 章节列表标题 ──
            Row() {
              Text('章节列表')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#333333')

              Blank()

              Text(`${this.chapters.length} 章`)
                .fontSize(13)
                .fontColor('#999999')
                .margin({ right: 8 })

              Image($r('sys.symbol.chevron_down'))
                .width(16)
                .height(16)
                .fillColor('#999999')
                .rotate({ angle: this.isChapterExpanded ? 180 : 0 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 8 })
            .backgroundColor('#FAFAFA')
            .onClick(() => { this.isChapterExpanded = !this.isChapterExpanded; })

            // ── 章节列表 ──
            if (this.isChapterExpanded) {
              ForEach(this.chapters, (photo: PhotoViewModel, index: number) => {
                Row() {
                  Text(`${index + 1}`)
                    .fontSize(14)
                    .fontColor('#999999')
                    .width(30)
                    .textAlign(TextAlign.Center)

                  Text(photo.name)
                    .fontSize(15)
                    .fontColor('#333333')
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ left: 8 })

                  Image($r('sys.symbol.chevron_right'))
                    .width(16)
                    .height(16)
                    .fillColor('#CCCCCC')
                }
                .width('100%')
                .height(52)
                .padding({ left: 16, right: 16 })
                .backgroundColor('#FFFFFF')
                .onClick(() => this.onChapterClick(photo))
              }, (item: PhotoViewModel) => item.id.toString())
            }

            // 相关作品
            if (this.album.related_list && this.album.related_list.length > 0) {
              Column() {
                Text('相关作品')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#333333')
                  .width('100%')
                  .padding({ left: 16, top: 16, bottom: 8 })
                  .backgroundColor('#FAFAFA')

                ForEach(this.album.related_list, (work: JmRelatedWork) => {
                  Row() {
                    Image(this.apiService.buildCoverUrl(work.id, ''))
                      .width(60)
                      .height(80)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(4)
                      .backgroundColor('#F0F0F0')

                    Column() {
                      Text(work.name)
                        .fontSize(14)
                        .fontColor('#333333')
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      Text(work.author)
                        .fontSize(12)
                        .fontColor('#999999')
                        .margin({ top: 4 })
                    }
                    .layoutWeight(1)
                    .margin({ left: 12 })
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .backgroundColor('#FFFFFF')
                  .onClick(() => {
                    router.replaceUrl({
                      url: 'pages/AlbumDetailPage',
                      params: { albumId: work.id, albumName: work.name }
                    });
                  })
                })
              }
              .width('100%')
            }

            // 底部占位
            Column().height(20)
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
      } else {
        Column() {
          Text('加载失败，请重试')
            .fontSize(16)
            .fontColor('#999999')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // ── 沉浸式顶部导航栏（毛玻璃浮层） ──
      Row() {
        Image($r('sys.symbol.chevron_left'))
          .width(24)
          .height(24)
          .fillColor('#333333')
          .onClick(() => this.onBack())

        Text('详情')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .maxLines(1)

        // 占位保持对称
        Image($r('sys.symbol.chevron_left'))
          .width(24)
          .height(24)
          .fillColor(Color.Transparent)
      }
      .position({ x: 0, y: 0 })
      .width('100%')
      .padding({ left: 12, right: 12, top: this.topSafeHeight + 20, bottom: 4 })
      .backgroundColor('rgba(255, 255, 255, 0.85)')
      .backdropBlur(20)
      .zIndex(10)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
