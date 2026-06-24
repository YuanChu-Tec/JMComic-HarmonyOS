import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { ApiService } from '../network/ApiService';
import { CacheManager } from '../common/CacheManager';
import { ImageDecodeUtils } from '../common/ImageDecodeUtils';
import { APP_HEADERS_IMAGE } from '../common/Constants';
import { JmImageInfo, PictureData } from '../models/Album';

interface ChapterInfo {
  photoId: string;
  photoName: string;
}

interface RouterParams {
  photoId: string;
  photoName: string;
  scrambleId: number;
  albumId: number;
  albumName: string;
  chaptersStr?: string;        // 章节列表 JSON 字符串
  currentChapterIndex?: number;
}

// ── LazyForEach 数据源 ──
class ImageDataSource implements IDataSource {
  private images: JmImageInfo[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.images.length;
  }

  getData(index: number): JmImageInfo {
    return this.images[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    let pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** 整体替换数据并触发全量刷新 */
  reload(images: JmImageInfo[]): void {
    this.images = images;
    this.listeners.forEach(l => l.onDataReloaded());
  }
}

@Entry
@Component
struct ImageViewerPage {
  @State images: JmImageInfo[] = [];
  @State isLoading: boolean = true;
  @State titleText: string = '';
  @State showControls: boolean = true;
  @State errorText: string = '';
  @State currentVisibleIndex: number = 0;
  @State decodedPixelMaps: (image.PixelMap | null)[] = [];
  @State hasPrevChapter: boolean = false;
  @State hasNextChapter: boolean = false;
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private photoId: string = '';
  private scrambleId: number = 0;
  private albumId: number = 0;
  private albumName: string = '';
  private chapters: ChapterInfo[] = [];
  private currentChapterIndex: number = 0;
  private apiService: ApiService = ApiService.getInstance();
  private cache: CacheManager | null = null;
  private totalImages: number = 0;
  private listScroller: Scroller = new Scroller();
  private decodingInFlight: boolean[] = [];
  private chapterGeneration: number = 0;
  private imageDataSource: ImageDataSource = new ImageDataSource();
  // 后台持续加载相关
  private backgroundLoaderActive: boolean = false;
  private nextLoadIndex: number = 0;       // 下一个要加载的索引
  private activeLoadCount: number = 0;      // 当前活跃加载数
  private maxConcurrentLoads: number = 3;   // 最大并发加载数

  aboutToAppear(): void {
    let params = router.getParams() as RouterParams;
    if (params) {
      this.photoId = params.photoId;
      this.scrambleId = params.scrambleId;
      this.albumId = params.albumId;
      this.albumName = params.albumName || '';
      this.titleText = params.photoName || '';
      this.currentChapterIndex = params.currentChapterIndex ?? 0;
      // 从 JSON 字符串解析章节列表
      if (params.chaptersStr) {
        try {
          this.chapters = JSON.parse(params.chaptersStr) as ChapterInfo[];
        } catch (e) {
          console.error('[ImageViewer] parse chaptersStr failed:', JSON.stringify(e));
        }
      }
      this.updateChapterButtons();
    }
    this.loadImagesWithCache();
  }

  async loadImagesWithCache(): Promise<void> {
    this.isLoading = true;
    this.errorText = '';

    try {
      this.cache = await CacheManager.getInstance();

      // 尝试从缓存加载
      let cached = this.cache!.loadChapterData(this.photoId);
      let data: PictureData | null = null;

      if (cached) {
        try {
          data = JSON.parse(cached) as PictureData;
          console.info(`[ImageViewer] loaded chapter data from cache: ${this.photoId}`);
        } catch {
          console.warn(`[ImageViewer] parse cached chapter data failed, fetching from API`);
        }
      }

      // 缓存未命中则请求 API
      if (!data) {
        data = await this.apiService.getChapterPictures(this.photoId, this.scrambleId);
        // 持久化到缓存
        try {
          this.cache!.saveChapterData(this.photoId, JSON.stringify(data));
          console.info(`[ImageViewer] saved chapter data to cache: ${this.photoId}`);
        } catch (e) {
          console.warn(`[ImageViewer] save cache failed: ${JSON.stringify(e)}`);
        }
      }

      if (data && data.pictures && data.pictures.images) {
        this.images = data.pictures.images;
        this.imageDataSource.reload(this.images);
        this.totalImages = this.images.length;
        this.titleText = data.pictures.name || this.titleText;
        if (data.pictures.scramble_id) {
          this.scrambleId = data.pictures.scramble_id;
        }
        // 初始化像素映射数组
        let arr: (image.PixelMap | null)[] = [];
        let flight: boolean[] = [];
        for (let i = 0; i < this.totalImages; i++) {
          arr.push(null);
          flight.push(false);
        }
        this.decodedPixelMaps = arr;
        this.decodingInFlight = flight;
        // 重置后台加载器状态
        this.nextLoadIndex = 0;
        this.backgroundLoaderActive = true;
        // 启动后台持续加载
        this.startBackgroundLoader();
      }
    } catch (err) {
      let errMsg = err instanceof Error ? err.message : JSON.stringify(err);
      console.error('loadImages error:', errMsg);
      this.errorText = errMsg || '加载图片失败，请重试';
    } finally {
      this.isLoading = false;
    }
    // 标记该章节为已读
    this.cache?.markChapterRead(this.albumId, this.photoId);
  }

  onBack(): void {
    router.back();
  }

  toggleControls(): void {
    this.showControls = !this.showControls;
  }

  private updateChapterButtons(): void {
    this.hasPrevChapter = this.currentChapterIndex > 0;
    this.hasNextChapter = this.chapters.length > 0 && this.currentChapterIndex < this.chapters.length - 1;
    console.info(`[ImageViewer] chapters=${this.chapters.length}, index=${this.currentChapterIndex}, prev=${this.hasPrevChapter}, next=${this.hasNextChapter}`);
  }

  goPrevChapter(): void {
    if (!this.hasPrevChapter) return;
    let prev = this.chapters[this.currentChapterIndex - 1];
    this.switchToChapter(prev, this.currentChapterIndex - 1);
  }

  goNextChapter(): void {
    if (!this.hasNextChapter) return;
    let next = this.chapters[this.currentChapterIndex + 1];
    this.switchToChapter(next, this.currentChapterIndex + 1);
  }

  private switchToChapter(chapter: ChapterInfo, index: number): void {
    this.chapterGeneration++;  // 作废旧解码任务
    this.backgroundLoaderActive = false;  // 停止后台加载
    this.photoId = chapter.photoId;
    this.titleText = chapter.photoName || '';
    this.currentChapterIndex = index;
    this.currentVisibleIndex = 0;
    this.images = [];
    this.imageDataSource.reload([]);
    this.decodedPixelMaps = [];
    this.decodingInFlight = [];
    this.totalImages = 0;
    this.updateChapterButtons();
    this.listScroller.scrollToIndex(0);
    this.loadImagesWithCache();
  }

  /**
   * 下载并解码指定索引的图片
   */
  async decodeImageAtIndex(index: number): Promise<void> {
    if (index < 0 || index >= this.images.length) {
      return;
    }
    if (this.decodedPixelMaps[index]) {
      return;
    }
    if (this.decodingInFlight[index]) {
      return;
    }
    this.decodingInFlight[index] = true;
    this.activeLoadCount++;

    let img = this.images[index];
    let url = img.img_url || img.download_url;
    if (!url || url.length === 0) {
      this.decodingInFlight[index] = false;
      this.activeLoadCount--;
      return;
    }

    let gen = this.chapterGeneration;
    console.info(`[ImageViewer] decoding image ${index + 1}/${this.totalImages}: ${url}`);

    try {
      // 1. 下载图片原始字节
      let request = http.createHttp();
      let response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: APP_HEADERS_IMAGE,
        connectTimeout: 15000,
        readTimeout: 30000,
      });

      if (gen !== this.chapterGeneration) {
        request.destroy();
        return;
      }

      if (response.responseCode !== 200) {
        console.warn(`[ImageViewer] download failed: HTTP ${response.responseCode}`);
        request.destroy();
        this.decodingInFlight[index] = false;
        return;
      }

      let arrayBuffer = response.result as ArrayBuffer;
      request.destroy();

      // 2. 创建 PixelMap
      let imageSource = image.createImageSource(arrayBuffer);
      let decodeOpts: image.DecodingOptions = {
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      };
      let pixelMap = await imageSource.createPixelMap(decodeOpts);
      imageSource.release();

      if (gen !== this.chapterGeneration) {
        return;
      }

      // 3. 计算分割数并解码
      let imgNameNoExt = img.img_name.replace(/\.[^.]+$/, '');
      let num = await ImageDecodeUtils.getSegmentationNum(
        this.scrambleId,
        parseInt(this.photoId),
        imgNameNoExt
      );

      if (gen !== this.chapterGeneration) {
        return;
      }

      console.info(`[ImageViewer] segmentation num=${num}, scrambleId=${this.scrambleId}, photoId=${this.photoId}`);

      if (num > 0) {
        pixelMap = await ImageDecodeUtils.decodeImage(pixelMap, num);
      }

      // 用 splice 确保 @State 响应式更新
      this.decodedPixelMaps.splice(index, 1, pixelMap);
    } catch (err) {
      console.error(`[ImageViewer] decode error at index ${index}: ${JSON.stringify(err)}`);
    } finally {
      this.decodingInFlight[index] = false;
      this.activeLoadCount--;
      // 触发后台继续加载下一张
      this.continueBackgroundLoading();
    }
  }

  /**
   * 启动后台持续加载器（限制并发数）
   */
  private startBackgroundLoader(): void {
    if (!this.backgroundLoaderActive) {
      return;
    }
    console.info(`[ImageViewer] background loader started, total=${this.totalImages}`);
    // 启动 maxConcurrentLoads 个并发任务
    for (let i = 0; i < this.maxConcurrentLoads; i++) {
      this.loadNextImage();
    }
  }

  /**
   * 加载下一个未加载的图片
   */
  private loadNextImage(): void {
    if (!this.backgroundLoaderActive) {
      return;
    }
    // 找到下一个未加载的图片
    while (this.nextLoadIndex < this.totalImages) {
      let index = this.nextLoadIndex;
      this.nextLoadIndex++;
      if (!this.decodedPixelMaps[index] && !this.decodingInFlight[index]) {
        // 异步加载，不等待
        this.decodeImageAtIndex(index);
        return;
      }
    }
    // 所有图片已加载完成
    this.backgroundLoaderActive = false;
    console.info('[ImageViewer] background loader finished');
  }

  /**
   * 当前图片加载完成后，继续加载下一张（只在活跃数低于上限时启动）
   */
  private continueBackgroundLoading(): void {
    if (this.backgroundLoaderActive) {
      // 保持并发数稳定：每完成一个任务，立即补一个新任务
      this.loadNextImage();
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#FF5A5F')
          Text('加载图片中...')
            .fontSize(14)
            .fontColor('#999999')
            .margin({ top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#1A1A1A')
      } else if (this.errorText.length > 0) {
        Column() {
          Text(this.errorText)
            .fontSize(16)
            .fontColor('#FF5A5F')
            .margin({ bottom: 16 })
          Button('重试')
            .fontSize(14)
            .backgroundColor('#FF5A5F')
            .fontColor('#FFFFFF')
            .borderRadius(6)
            .onClick(() => this.loadImagesWithCache())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#1A1A1A')
      } else if (this.images.length === 0) {
        Column() {
          Text('暂无图片')
            .fontSize(16)
            .fontColor('#999999')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#1A1A1A')
      } else {
        // 垂直滚动图片列表（LazyForEach 懒加载，避免大量图片同时渲染）
        List({ scroller: this.listScroller }) {
          LazyForEach(this.imageDataSource, (img: JmImageInfo, index: number) => {
            ListItem() {
              if (this.decodedPixelMaps[index]) {
                Image(this.decodedPixelMaps[index])
                  .width('100%')
                  .objectFit(ImageFit.Contain)
                  .backgroundColor('#FFFFFF')
              } else {
                Image($r('app.media.loading'))
                  .width('100%')
                  .objectFit(ImageFit.Contain)
                  .backgroundColor('#FFFFFF')
              }
            }
            .width('100%')
            .onAppear(() => {
              this.decodeImageAtIndex(index);
              // 预解码下一张
              if (index + 1 < this.totalImages) {
                this.decodeImageAtIndex(index + 1);
              }
            })
          }, (img: JmImageInfo, index: number) => `${index}`)
        }
        .listDirection(Axis.Vertical)
        .scrollBar(BarState.Off)
        .cachedCount(2)
        .onScrollIndex((firstVisible: number, _: number) => {
          this.currentVisibleIndex = firstVisible;
        })
        .onClick(() => this.toggleControls())
        .width('100%')
        .height('100%')

        // ── 悬浮顶部工具栏 ──
        if (this.showControls) {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(24)
              .fontColor(['#FFFFFF'])
              .onClick(() => this.onBack())

            Text(`第${this.currentChapterIndex + 1}章 - ${this.titleText}`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 8, right: 8 })

            // 占位保持标题居中
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(24)
              .fontColor(['#00000000'])
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: this.topSafeHeight + 8, bottom: 8 })
          .backgroundColor('rgba(0,0,0,0.5)')
          .backdropBlur(20)

          // ── 悬浮底部工具栏 ──
          Row() {
            Button(this.hasPrevChapter ? '上一章' : '已是第一章')
              .fontSize(14)
              .fontColor(this.hasPrevChapter ? '#FFFFFF' : '#666666')
              .backgroundColor(this.hasPrevChapter ? 'rgba(255,90,95,0.9)' : 'rgba(100,100,100,0.5)')
              .borderRadius(18)
              .width(100)
              .height(36)
              .enabled(this.hasPrevChapter)
              .onClick(() => this.goPrevChapter())

            Text(`${this.currentVisibleIndex + 1} / ${this.totalImages}`)
              .fontSize(13)
              .fontColor('#AAAAAA')
              .layoutWeight(1)
              .textAlign(TextAlign.Center)

            Button(this.hasNextChapter ? '下一章' : '已是最后一章')
              .fontSize(14)
              .fontColor(this.hasNextChapter ? '#FFFFFF' : '#666666')
              .backgroundColor(this.hasNextChapter ? 'rgba(255,90,95,0.9)' : 'rgba(100,100,100,0.5)')
              .borderRadius(18)
              .width(100)
              .height(36)
              .enabled(this.hasNextChapter)
              .onClick(() => this.goNextChapter())
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: this.bottomSafeHeight + 8 })
          .backgroundColor('rgba(0,0,0,0.5)')
          .backdropBlur(20)
          .justifyContent(FlexAlign.SpaceBetween)
          .position({ x: 0, y: '100%' })
          .translate({ y: '-100%' })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1A1A1A')
  }
}
