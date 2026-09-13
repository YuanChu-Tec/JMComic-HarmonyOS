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
  // 阅读模式：'scroll' 竖向滚动(下) / 'paged_ltr' 横向从左往右(西漫) / 'paged_rtl' 横向从右往左(日漫)
  @State readerMode: string = 'scroll';
  @State isPagedMode: boolean = false;
  @State isRtl: boolean = false;
  // 箭头旋转角度（基础图标为指向正下的 arrow_down，按模式旋转得到各方向）：scroll→0°(下) / paged_ltr→-90°(右) / paged_rtl→90°(左)
  @State rotateAngle: number = 0;
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
  // 恢复落点稳定前禁止上报/写盘，避免跳转过程中的瞬时索引污染记录
  private restoreGuard: boolean = false;
  // 阅读位置保存防抖定时器
  private saveTimer: number = -1;
  // 横向翻页（Swiper）控制器
  private swiperController: SwiperController = new SwiperController();
  // 横向翻页恢复目标页（用于 guard 判定）
  private restorePageTarget: number = -1;
  // Swiper 初始显示索引：仅在挂载时生效，进入/切章时直接定位到目标页（无滑动动画）
  private swiperInitialIndex: number = 0;
  // 翻转以强制 Swiper 在切章时重建（回到首页），避免沿用上一章索引
  @State swiperToggle: boolean = false;

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
      // 读取用户上次选择的阅读模式（竖向滚动 / 横向翻页方向）
      let mode = this.cache.getReaderMode();
      this.readerMode = mode;
      this.isPagedMode = (mode !== 'scroll');
      this.isRtl = (mode === 'paged_rtl');
      this.rotateAngle = this.directionAngle(mode);
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
        // 恢复上次阅读位置
        this.restoreReadPosition();
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

  aboutToDisappear(): void {
    // 页面销毁时落盘，保证最后阅读位置不丢
    this.flushSavePosition();
  }

  onBack(): void {
    this.flushSavePosition();
    router.back();
  }

  toggleControls(): void {
    this.showControls = !this.showControls;
  }

  /**
   * 循环切换阅读方向：下滑动(竖向) -> 右翻页(西漫LTR) -> 左翻页(日漫RTL) -> 下滑动
   * 箭头指示当前翻页/滑动方向；切换后重新定位到当前页，避免布局变化导致位置错乱。
   */
  cycleReaderMode(): void {
    let order: string[] = ['scroll', 'paged_ltr', 'paged_rtl'];
    let next = order[(order.indexOf(this.readerMode) + 1) % order.length];
    let idx = this.currentVisibleIndex;
    let gen = this.chapterGeneration;
    this.readerMode = next;
    this.isPagedMode = (next !== 'scroll');
    this.isRtl = (next === 'paged_rtl');
    this.rotateAngle = this.directionAngle(next);
    this.cache?.setReaderMode(next);
    if (next !== 'scroll') {
      // 进入/切换横向翻页：按 RTL 映射设置初始索引，挂载时直接定位；翻转 swiperToggle 重建 Swiper
      this.swiperInitialIndex = this.isRtl ? (this.totalImages - 1 - idx) : idx;
      this.restoreGuard = true;
      this.swiperToggle = !this.swiperToggle;
      setTimeout(() => {
        if (gen === this.chapterGeneration) {
          this.restoreGuard = false;
        }
      }, 400);
    } else {
      setTimeout(() => {
        if (gen === this.chapterGeneration) {
          this.listScroller.scrollToIndex(idx, false, ScrollAlign.START);
        }
      }, 60);
    }
  }

  /** 阅读模式 -> 箭头旋转角度（基础图标 arrow_down 指向正下：scroll 下=0° / paged_ltr 右=-90° / paged_rtl 左=90°） */
  private directionAngle(mode: string): number {
    let base: number = mode === 'scroll' ? 0 : (mode === 'paged_rtl' ? 90 : -90);
    // 取一个不大于当前角度的等价角(±360)，使箭头始终沿同一方向(逆时针)平滑旋转：
    // 右切左(0°→-180°)经上方过渡，而不是顺时针经过下方(=滚动方向)，避免误以为切到滚动模式。
    let target: number = base;
    while (target > this.rotateAngle) {
      target -= 360;
    }
    return target;
  }

  /**
   * 横向翻页恢复定位。
   * 本 SDK 的 SwiperController 无 changeTo，故利用 Swiper 的 index 初始索引：
   * 加载期间 Swiper 未挂载（isLoading 为真时整页是加载界面），加载完成后 Swiper 以
   * swiperInitialIndex 作为初始索引直接挂载到目标页，无滑动动画。
   */
  private beginSwiperRestore(target: number, gen: number): void {
    // 自然页码 -> Swiper 下标（RTL 反转）。加载期间 Swiper 未挂载，加载后以此索引直接定位
    this.swiperInitialIndex = this.isRtl ? (this.totalImages - 1 - target) : target;
    this.restorePageTarget = target;
    this.currentVisibleIndex = target;
    this.restoreGuard = true;
    // 挂载/落点稳定后再开放索引上报与写盘
    setTimeout(() => {
      if (gen === this.chapterGeneration) {
        this.restoreGuard = false;
        this.restorePageTarget = -1;
      }
    }, 400);
  }

  /**
   * 恢复上次阅读位置
   * 关键点：必须显式 ScrollAlign.START 顶部对齐。图片等比缩放后高度常小于视口，
   * 默认的 AUTO 会把目标项贴底、上方露出上一项，导致首个可见项变成 target-1，
   * 进而每次进入记录的页码都退 1 页。
   */
  private restoreReadPosition(): void {
    let saved = this.cache ? this.cache.getReadPosition(this.albumId, this.photoId) : -1;
    let valid = saved > 0 && saved < this.totalImages;
    let target = valid ? saved : 0;
    let gen = this.chapterGeneration;

    if (this.isPagedMode) {
      // Swiper 在切章时已重建回首页(0)；无记录回到首页，有记录则逐步翻到目标页
      let t = valid ? target : 0;
      console.info(`[ImageViewer] restore target: ${t + 1}/${this.totalImages}`);
      this.beginSwiperRestore(t, gen);
      return;
    }

    if (!valid) return;
    this.restoreGuard = true;
    this.currentVisibleIndex = target;
    // 图片解码前后 item 高度会变化，需要重复校正落点
    let delays: number[] = [80, 400];
    for (let d of delays) {
      let isLast: boolean = (d === delays[delays.length - 1]);
      setTimeout(() => {
        if (gen !== this.chapterGeneration) {
          this.restoreGuard = false;
          return;
        }
        this.listScroller.scrollToIndex(target, false, ScrollAlign.START);
        this.loadPixelMap(target);
        this.preloadNearbyPixelMaps(target);
        console.info(`[ImageViewer] restored read position: ${target + 1}/${this.totalImages}`);
        if (isLast) {
          this.currentVisibleIndex = target;
          // 落点稳定后再开放索引上报与写盘
          setTimeout(() => {
            if (gen === this.chapterGeneration) {
              this.restoreGuard = false;
            }
          }, 400);
        }
      }, d);
    }
  }

  /**
   * 横向翻页（Swiper）内容。抽成 @Builder 以便通过 swiperToggle 翻转在两个分支间切换，
   * 从而在切章时强制销毁并重建 Swiper（回到首页），避免沿用上一章索引。
   */
  @Builder
  private swiperContent() {
    Swiper(this.swiperController) {
      LazyForEach(this.imageDataSource, (img: JmImageInfo, index: number) => {
        this.swiperItem(index)
      }, (img: JmImageInfo, index: number) => `${this.isRtl ? (this.totalImages - 1 - index) : index}`)
    }
    .width('100%')
    .height('100%')
    .indicator(false)
    .loop(false)
    // 初始显示索引：仅挂载时生效，用于进入/切章时直接定位到目标页（无滑动动画）
    .index(this.swiperInitialIndex)
    .cachedCount(2)
    .duration(150)
    // 放大时禁用翻页，改由外层 Scroll 平移看图（避免手势冲突）
    .disableSwipe(this.isZoomed)
    .onChange((index: number) => {
      // Swiper 下标 -> 自然页码（RTL 反转）
      let natural = this.isRtl ? (this.totalImages - 1 - index) : index;
      if (this.restoreGuard) {
        // 恢复阶段：仅同步索引，定位已由 Swiper 初始索引完成，无需逐步翻页
        this.currentVisibleIndex = natural;
        return;
      }
      if (natural >= 0 && natural !== this.currentVisibleIndex) {
        this.currentVisibleIndex = natural;
        this.scheduleSavePosition(natural);
      }
    })
  }

  /**
   * Swiper 单页内容（抽出为 @Builder，避免在 LazyForEach 生成函数体内写 let 触发 UI 语法限制）。
   * 参数 index 为 Swiper 下标；RTL 模式下按 natural = total-1-index 映射回自然页号。
   */
  @Builder
  private swiperItem(index: number) {
    Column() {
      if (this.decodedPixelMaps[this.isRtl ? (this.totalImages - 1 - index) : index]) {
        Image(this.decodedPixelMaps[this.isRtl ? (this.totalImages - 1 - index) : index])
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor('#FFFFFF')
      } else {
        Image($r('app.media.loading'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onAppear(() => {
      let natural: number = this.isRtl ? (this.totalImages - 1 - index) : index;
      this.loadPixelMap(natural);
      this.preloadNearbyPixelMaps(natural);
    })
    .onDisAppear(() => {
      let natural: number = this.isRtl ? (this.totalImages - 1 - index) : index;
      let pm = this.decodedPixelMaps[natural];
      if (pm) {
        pm.release();
        this.decodedPixelMaps.splice(natural, 1, null);
      }
    })
  }

  /** 防抖保存阅读位置（快速滑动时不频繁落盘） */
  private scheduleSavePosition(index: number): void {
    // 恢复过程中不写盘，避免跳转产生的瞬时索引覆盖真实位置
    if (this.restoreGuard) {
      return;
    }
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = -1;
      this.cache?.saveReadPosition(this.albumId, this.photoId, index, this.totalImages);
    }, 500);
  }

  /** 立即保存阅读位置（退出 / 切章前调用） */
  private flushSavePosition(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    if (this.totalImages > 0) {
      this.cache?.saveReadPosition(this.albumId, this.photoId, this.currentVisibleIndex, this.totalImages);
    }
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
    // 先保存当前章节的阅读位置
    this.flushSavePosition();
    this.restoreGuard = false;
    this.chapterGeneration++;
    // 翻转以强制重建 Swiper（回到首页），避免横向翻页模式下沿用上一章索引
    this.swiperToggle = !this.swiperToggle;
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
          if (this.isPagedMode) {
            // 两个分支都渲染同一个 Swiper；借助 swiperToggle 翻转，可在切章时强制销毁并重建
            // Swiper，使其回到首页(index=0)，避免沿用上一章索引导致恢复页码错乱/后退
            if (this.swiperToggle) {
              this.swiperContent();
            } else {
              this.swiperContent();
            }
          } else {
            // 竖向滚动模式：List 连续纵向滚动
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
                  // 只负责加载：cachedCount(10) 会让屏外 ±10 项也触发 onAppear，
                  // 用它算页码会偏很多，页码统一交给 List.onScrollIndex 上报
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
            // 未缩放时由 List 纵向滚动，滑条走内层；放大后交给外层 Scroll
            .scrollBar(this.isZoomed ? BarState.Off : BarState.Auto)
            .scrollBarColor('#BBBBBB')
            .scrollBarWidth(6)
            .cachedCount(10)
            .onScrollIndex((start: number) => {
              // 首可见项变化时回调，是当前页码唯一准确的来源
              if (this.restoreGuard) {
                return;
              }
              if (start >= 0 && start !== this.currentVisibleIndex) {
                this.currentVisibleIndex = start;
                this.scheduleSavePosition(start);
              }
            })
            .width('100%')
            .height('100%')
            .nestedScroll({
              scrollForward: NestedScrollMode.PARENT_FIRST,
              scrollBackward: NestedScrollMode.PARENT_FIRST
            })
          }
        }
        .width('100%')
        .height('100%')
        // 仅缩放时允许外层 Scroll 平移；未缩放时交给内层 Swiper/List 处理手势，避免到末页被外层抢手势
        .scrollable(this.isZoomed ? ScrollDirection.FREE : ScrollDirection.None)
        .maxZoomScale(3.0)
        .minZoomScale(1.0)
        .zoomScale(this.zoomScale)
        .enableBouncesZoom(true)
        .edgeEffect(EdgeEffect.None)
        // 放大后由外层 Scroll 接管滚动（PARENT_FIRST），滑条走外层。
        // 用 On 而不用 Auto：缩放态下拖拽是"平移"，Auto 常驻判定不稳定会不显示，
        // 且 Auto 2 秒后自动隐藏，放大阅读时反而看不到进度。
        .scrollBar(this.isZoomed ? BarState.On : BarState.Off)
        .scrollBarColor('#BBBBBB')
        .scrollBarWidth(6)
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

            Button({ type: ButtonType.Normal }) {
              SymbolGlyph($r('sys.symbol.arrow_down'))
                .fontSize(22)
                .fontColor(['#FFFFFF'])
                // 基础箭头指向正下(0°)，按当前模式旋转到对应方向；属性动画使切换方向时平滑旋转
                .rotate({ angle: this.rotateAngle })
                .animation({ duration: 300, curve: Curve.EaseOut })
            }
              .backgroundColor('rgba(100,100,100,0.5)')
              .borderRadius(18)
              .width(44)
              .height(36)
              .onClick(() => this.cycleReaderMode())

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
