import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { ApiService } from '../network/ApiService';
import { CacheManager } from '../common/CacheManager';
import { ImageDecodeUtils } from '../common/ImageDecodeUtils';
import { DecodedImageCache } from '../common/DecodedImageCache';
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
  chaptersStr?: string;
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
  @State isZoomed: boolean = false;
  private zoomScale: number = 1.0;
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
  private decodedCache: DecodedImageCache | null = null;
  private totalImages: number = 0;
  private scrollScroller: Scroller = new Scroller();
  private listScroller: Scroller = new Scroller();
  private chapterGeneration: number = 0;
  private imageDataSource: ImageDataSource = new ImageDataSource();
  // 后台预加载：下载+拼图解码+写PNG，不涉及 UI
  private preloadActive: boolean = false;
  private preloadIndex: number = 0;
  private preloadInFlight: number = 0;
  private maxPreloadConcurrent: number = 3;
  // 前台加载：从磁盘 PNG 创建 PixelMap
  private uiLoadInFlight: Set<number> = new Set();

  aboutToAppear(): void {
    let params = router.getParams() as RouterParams;
    if (params) {
      this.photoId = params.photoId;
      this.scrambleId = params.scrambleId;
      this.albumId = params.albumId;
      this.albumName = params.albumName || '';
      this.titleText = params.photoName || '';
      this.currentChapterIndex = params.currentChapterIndex ?? 0;
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
      this.decodedCache = await DecodedImageCache.getInstance();

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

      if (!data) {
        data = await this.apiService.getChapterPictures(this.photoId, this.scrambleId);
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
        // 初始化 PixelMap 数组
        let arr: (image.PixelMap | null)[] = [];
        for (let i = 0; i < this.totalImages; i++) {
          arr.push(null);
        }
        this.decodedPixelMaps = arr;
        // 启动后台预加载器
        this.preloadIndex = 0;
        this.preloadActive = true;
        this.startPreloader();
      }
    } catch (err) {
      let errMsg = err instanceof Error ? err.message : JSON.stringify(err);
      console.error('loadImages error:', errMsg);
      this.errorText = errMsg || '加载图片失败，请重试';
    } finally {
      this.isLoading = false;
    }
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
    this.chapterGeneration++;
    this.preloadActive = false;
    this.photoId = chapter.photoId;
    this.titleText = chapter.photoName || '';
    this.currentChapterIndex = index;
    this.currentVisibleIndex = 0;
    this.images = [];
    this.imageDataSource.reload([]);
    this.decodedPixelMaps = [];
    this.totalImages = 0;
    this.updateChapterButtons();
    this.zoomScale = 1.0;
    this.isZoomed = false;
    this.scrollScroller.scrollEdge(Edge.Top);
    this.loadImagesWithCache();
  }

  // ═══════════════════════════════════════════════════════
  // 后台预加载：下载 + 拼图解码 + 写 PNG 到磁盘
  // 纯 IO，不触发任何 @State 更新
  // ═══════════════════════════════════════════════════════

  private startPreloader(): void {
    if (!this.preloadActive) return;
    console.info(`[Preloader] started, total=${this.totalImages}`);
    for (let i = 0; i < this.maxPreloadConcurrent; i++) {
      this.preloadNext();
    }
  }

  private preloadNext(): void {
    if (!this.preloadActive) return;
    while (this.preloadIndex < this.totalImages) {
      let idx = this.preloadIndex;
      this.preloadIndex++;
      // 已有磁盘缓存则跳过
      if (this.decodedCache && this.decodedCache.hasCached(this.photoId, idx)) {
        continue;
      }
      this.preloadInFlight++;
      this.preloadToDisk(idx);
      return;
    }
    // 全部完成
    if (this.preloadInFlight <= 0) {
      this.preloadActive = false;
      console.info('[Preloader] all images preloaded');
    }
  }

  private async preloadToDisk(index: number): Promise<void> {
    let gen = this.chapterGeneration;
    try {
      // 再次检查磁盘缓存（可能其他任务已写入）
      if (this.decodedCache && this.decodedCache.hasCached(this.photoId, index)) {
        return;
      }

      let img = this.images[index];
      let url = img.img_url || img.download_url;
      if (!url || url.length === 0) return;

      // 1. 下载原始字节
      let request = http.createHttp();
      let response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: APP_HEADERS_IMAGE,
        connectTimeout: 15000,
        readTimeout: 30000,
      });
      if (gen !== this.chapterGeneration) { request.destroy(); return; }
      if (response.responseCode !== 200) { request.destroy(); return; }

      let arrayBuffer = response.result as ArrayBuffer;
      request.destroy();

      // 2. 创建 PixelMap
      let imageSource = image.createImageSource(arrayBuffer);
      let decodeOpts: image.DecodingOptions = {
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      };
      let pixelMap = await imageSource.createPixelMap(decodeOpts);
      imageSource.release();
      if (gen !== this.chapterGeneration) { pixelMap.release(); return; }

      // 3. 拼图解码
      let imgNameNoExt = img.img_name.replace(/\.[^.]+$/, '');
      let num = await ImageDecodeUtils.getSegmentationNum(
        this.scrambleId,
        parseInt(this.photoId),
        imgNameNoExt
      );
      if (gen !== this.chapterGeneration) { pixelMap.release(); return; }

      if (num > 0) {
        pixelMap = await ImageDecodeUtils.decodeImage(pixelMap, num);
      }
      if (gen !== this.chapterGeneration) { pixelMap.release(); return; }

      // 4. 写 PNG 到磁盘
      if (this.decodedCache) {
        await this.decodedCache.saveDecodedImage(this.photoId, index, pixelMap);
      }

      // 5. 释放内存（磁盘已有备份）
      pixelMap.release();
      console.info(`[Preloader] saved ${index + 1}/${this.totalImages}`);
    } catch (err) {
      console.error(`[Preloader] error at ${index}: ${JSON.stringify(err)}`);
    } finally {
      this.preloadInFlight--;
      this.preloadNext();
    }
  }

  // ═══════════════════════════════════════════════════════
  // 前台加载：从磁盘 PNG 创建 PixelMap 显示
  // ═══════════════════════════════════════════════════════

  private async loadPixelMap(index: number): Promise<void> {
    if (index < 0 || index >= this.images.length) return;
    if (this.decodedPixelMaps[index]) return;
    if (this.uiLoadInFlight.has(index)) return;

    this.uiLoadInFlight.add(index);
    let gen = this.chapterGeneration;

    try {
      // 从磁盘 PNG 加载（毫秒级）
      if (this.decodedCache && this.decodedCache.hasCached(this.photoId, index)) {
        let pm = await this.decodedCache.loadDecodedImage(this.photoId, index);
        if (gen !== this.chapterGeneration) {
          if (pm) pm.release();
          return;
        }
        if (pm) {
          this.decodedPixelMaps.splice(index, 1, pm);
          return;
        }
      }

      // 磁盘缓存未命中（预加载还没到），降级走网络
      await this.fallbackLoadFromNetwork(index, gen);
    } finally {
      this.uiLoadInFlight.delete(index);
    }
  }

  private async fallbackLoadFromNetwork(index: number, gen: number): Promise<void> {
    let img = this.images[index];
    let url = img.img_url || img.download_url;
    if (!url || url.length === 0) return;

    console.info(`[ImageViewer] fallback network load: ${index + 1}/${this.totalImages}`);

    let request = http.createHttp();
    let response = await request.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      header: APP_HEADERS_IMAGE,
      connectTimeout: 15000,
      readTimeout: 30000,
    });
    if (gen !== this.chapterGeneration) { request.destroy(); return; }
    if (response.responseCode !== 200) { request.destroy(); return; }

    let arrayBuffer = response.result as ArrayBuffer;
    request.destroy();

    let imageSource = image.createImageSource(arrayBuffer);
    let pixelMap = await imageSource.createPixelMap({
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
    });
    imageSource.release();
    if (gen !== this.chapterGeneration) { pixelMap.release(); return; }

    let imgNameNoExt = img.img_name.replace(/\.[^.]+$/, '');
    let num = await ImageDecodeUtils.getSegmentationNum(
      this.scrambleId,
      parseInt(this.photoId),
      imgNameNoExt
    );
    if (gen !== this.chapterGeneration) { pixelMap.release(); return; }

    if (num > 0) {
      pixelMap = await ImageDecodeUtils.decodeImage(pixelMap, num);
    }
    if (gen !== this.chapterGeneration) { pixelMap.release(); return; }

    // 写入磁盘缓存 + 显示
    if (this.decodedCache) {
      this.decodedCache.saveDecodedImage(this.photoId, index, pixelMap);
    }
    this.decodedPixelMaps.splice(index, 1, pixelMap);
  }

  // ═══════════════════════════════════════════════════════
  // 缩放回调
  // ═══════════════════════════════════════════════════════

  /**
   * 预加载视口附近的 PixelMap（消除快速滑动闪占位图）
   * 在 onAppear 时调用，提前将 cachedCount 范围内的图片从磁盘加载到内存
   */
  private preloadNearbyPixelMaps(centerIndex: number): void {
    let range = 10;
    let low = Math.max(0, centerIndex - range);
    let high = Math.min(this.totalImages - 1, centerIndex + range);
    for (let i = low; i <= high; i++) {
      if (!this.decodedPixelMaps[i] && !this.uiLoadInFlight.has(i)) {
        this.loadPixelMap(i);
      }
    }
  }

  private onZoomStarted(): void {
  }

  private onZoomStopped(): void {
    if (this.isZoomed !== this.zoomScale > 1.0) {
      this.isZoomed = this.zoomScale > 1.0;
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
        Scroll(this.scrollScroller) {
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
                this.currentVisibleIndex = index;
                this.loadPixelMap(index);
                this.preloadNearbyPixelMaps(index);
              })
              .onDisAppear(() => {
                let pm = this.decodedPixelMaps[index];
                if (pm) {
                  pm.release();
                  this.decodedPixelMaps.splice(index, 1, null);
                }
              })
            }, (img: JmImageInfo, index: number) => `${index}`)
          }
          .listDirection(Axis.Vertical)
          .scrollBar(BarState.Off)
          .cachedCount(10)
          .width('100%')
          .height('100%')
          .nestedScroll({
            scrollForward: NestedScrollMode.PARENT_FIRST,
            scrollBackward: NestedScrollMode.PARENT_FIRST
          })
        }
        .width('100%')
        .height('100%')
        .scrollable(ScrollDirection.FREE)
        .maxZoomScale(3.0)
        .minZoomScale(1.0)
        .zoomScale(this.zoomScale)
        .enableBouncesZoom(true)
        .edgeEffect(EdgeEffect.None)
        .scrollBar(BarState.Off)
        .onZoomStart(() => {
          this.onZoomStarted();
        })
        .onDidZoom((scale: number) => {
          this.zoomScale = scale;
          let zoomed = scale > 1.0;
          if (this.isZoomed !== zoomed) {
            this.isZoomed = zoomed;
          }
        })
        .onZoomStop(() => {
          this.onZoomStopped();
        })
        .onClick(() => this.toggleControls())

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
