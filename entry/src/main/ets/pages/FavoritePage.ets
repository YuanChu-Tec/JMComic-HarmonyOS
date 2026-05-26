import { router } from '@kit.ArkUI';
import { ApiService } from '../network/ApiService';
import {
  AlbumViewModel,
  FavoriteAlbumItem,
  FavoriteFolderItem,
  FavoritePageData,
  FavoriteFolderType,
  IAlbumViewModelJSON,
} from '../models/Album';
import { CacheManager } from '../common/CacheManager';
import { PAGE_SIZE_FAVORITE } from '../common/Constants';

/**
 * 收藏页面
 * 展示用户收藏的本子，支持收藏夹切换、取消收藏、管理收藏夹
 */
@Entry
@Component
struct FavoritePage {
  @State albums: AlbumViewModel[] = [];
  @State folders: FavoriteFolderItem[] = [];
  @State currentFolderId: string = '0';
  @State isLoading: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State total: number = 0;
  @State showFolderDialog: boolean = false;
  @State newFolderName: string = '';
  @State editingFolderId: string = '';
  @State editingFolderName: string = '';
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private apiService: ApiService = new ApiService();
  private cache: CacheManager | null = null;

  async aboutToAppear(): Promise<void> {
    this.cache = await CacheManager.getInstance();
    // 先尝试缓存
    let loaded = await this.loadFromCache();
    if (!loaded) {
      await this.loadFavorites();
    }
  }

  aboutToDisappear(): void {
    this.apiService.destroy();
  }

  async loadFromCache(): Promise<boolean> {
    if (!this.cache) return false;
    let cachedPages = this.cache.getFavoritePages(this.currentFolderId);
    if (cachedPages.length === 0) return false;

    let allAlbums: AlbumViewModel[] = [];
    for (let p of cachedPages.sort((a, b) => a - b)) {
      let entry = this.cache.loadFavoriteList(this.currentFolderId, p);
      if (entry) {
        let items = AlbumViewModel.fromJSONArray(JSON.parse(entry.data) as IAlbumViewModelJSON[]);
        allAlbums = allAlbums.concat(items);
        if (entry.extra) {
          try {
            this.folders = JSON.parse(entry.extra) as FavoriteFolderItem[];
          } catch {
            // ignore
          }
        }
      }
    }
    if (allAlbums.length === 0) return false;

    this.albums = allAlbums;
    this.currentPage = cachedPages.length;
    this.hasMore = true; // 收藏可能有更多
    return true;
  }

  saveToCache(page: number, vms: AlbumViewModel[], total: number, folders: FavoriteFolderItem[]): void {
    if (!this.cache) return;
    let data = JSON.stringify(vms.map(vm => vm.toJSON()));
    let foldersJson = JSON.stringify(folders);
    this.cache.saveFavoriteList(this.currentFolderId, page, data, total, foldersJson);
  }

  async loadFavorites(): Promise<void> {
    if (this.isLoading) return;
    this.isLoading = true;

    try {
      let resp = await this.apiService.getFavorites(this.currentPage, this.currentFolderId);
      if (resp.code === 200 && resp.data) {
        let pageData = resp.data;
        this.total = pageData.total;
        this.folders = pageData.folder_list || [];

        let vms = pageData.list.map((item: FavoriteAlbumItem) => {
          let vm = new AlbumViewModel();
          vm.id = parseInt(item.id);
          vm.name = item.name;
          vm.author = Array.isArray(item.author) ? item.author.join(', ') : item.author;
          vm.description = item.description;
          vm.category = item.category?.title || '';
          vm.coverUrl = this.apiService.buildCoverUrl(vm.id);
          return vm;
        });

        if (this.currentPage === 1) {
          this.albums = vms;
        } else {
          this.albums = this.albums.concat(vms);
        }

        this.hasMore = this.albums.length < this.total;

        // 保存到本地缓存
        this.saveToCache(this.currentPage, vms, pageData.total, pageData.folder_list || []);
      }
    } catch (err) {
      console.error('loadFavorites error:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  onFolderChange(folderId: string): void {
    if (this.currentFolderId === folderId) return;
    this.currentFolderId = folderId;
    this.currentPage = 1;
    this.hasMore = true;
    this.albums = [];
    this.loadFavorites();
  }

  loadMore(): void {
    if (!this.hasMore || this.isLoading) return;
    this.currentPage++;
    this.loadFavorites();
  }

  onAlbumClick(album: AlbumViewModel): void {
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: { albumId: album.id, albumName: album.name }
    });
  }

  async onToggleFavorite(albumId: number): Promise<void> {
    try {
      let result = await this.apiService.toggleFavorite(albumId.toString());
      if (result.status === 'ok') {
        // 从列表中移除
        this.albums = this.albums.filter(a => a.id !== albumId);
        this.total--;
      }
    } catch (err) {
      console.error('toggleFavorite error:', JSON.stringify(err));
    }
  }

  // ─── 收藏夹管理 ───

  onShowAddFolder(): void {
    this.newFolderName = '';
    this.showFolderDialog = true;
  }

  async onConfirmAddFolder(): Promise<void> {
    if (!this.newFolderName.trim()) return;
    try {
      await this.apiService.manageFavoriteFolder(FavoriteFolderType.ADD, '', this.newFolderName.trim());
      this.showFolderDialog = false;
      this.newFolderName = '';
      // 重新加载收藏夹列表
      this.currentPage = 1;
      this.albums = [];
      await this.loadFavorites();
    } catch (err) {
      console.error('addFolder error:', JSON.stringify(err));
    }
  }

  async onDeleteFolder(folderId: string): Promise<void> {
    try {
      await this.apiService.manageFavoriteFolder(FavoriteFolderType.DELETE, folderId);
      this.folders = this.folders.filter(f => f.FID !== folderId);
      if (this.currentFolderId === folderId) {
        this.currentFolderId = '0';
        this.currentPage = 1;
        this.albums = [];
        await this.loadFavorites();
      }
    } catch (err) {
      console.error('deleteFolder error:', JSON.stringify(err));
    }
  }

  onBack(): void {
    router.back();
  }

  build() {
    Stack() {
      Column() {
        // ── 顶部标题栏 ──
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('←')
            .fontSize(20)
            .fontColor('#333333')
        }
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .onClick(() => this.onBack())

        Text('收藏夹')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Button({ type: ButtonType.Normal }) {
          Text('+ 新建')
            .fontSize(13)
            .fontColor('#FF5A5F')
        }
        .backgroundColor('#FFF0F0')
        .borderRadius(14)
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => this.onShowAddFolder())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor('#FFFFFF')

      // ── 收藏夹标签 ──
      if (this.folders.length > 0) {
        Scroll() {
          Row() {
            // "全部"标签
            Text('全部')
              .fontSize(13)
              .fontColor(this.currentFolderId === '0' ? '#FFFFFF' : '#666666')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.currentFolderId === '0' ? '#FF5A5F' : '#F5F5F5')
              .borderRadius(14)
              .margin({ right: 8 })
              .onClick(() => this.onFolderChange('0'))

            ForEach(this.folders, (folder: FavoriteFolderItem) => {
              Row() {
                Text(folder.name)
                  .fontSize(13)
                  .fontColor(this.currentFolderId === folder.FID ? '#FFFFFF' : '#666666')
                  .padding({ left: 12, right: 4, top: 6, bottom: 6 })

                if (folder.FID !== '0') {
                  Image($r('sys.media.ohos_ic_public_close'))
                    .width(12)
                    .height(12)
                    .fillColor(this.currentFolderId === folder.FID ? '#FFFFFF' : '#999999')
                    .margin({ right: 8, left: 2 })
                    .onClick(() => this.onDeleteFolder(folder.FID))
                }
              }
              .backgroundColor(this.currentFolderId === folder.FID ? '#FF5A5F' : '#F5F5F5')
              .borderRadius(14)
              .margin({ right: 8 })
              .onClick(() => this.onFolderChange(folder.FID))
            })
          }
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .backgroundColor('#FFFFFF')
        .height(48)
      }

      // ── 分割线 ──
      Divider()
        .height(1)
        .color('#F0F0F0')

      // ── 总数提示 ──
      Row() {
        Text(`共 ${this.total} 个收藏`)
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor('#FFFFFF')

      // ── 收藏列表 ──
      if (this.albums.length === 0 && this.isLoading) {
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
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.albums.length === 0) {
        Column() {
          Text('暂无收藏')
            .fontSize(16)
            .fontColor('#999999')
          Text('去发现页探索更多内容吧')
            .fontSize(13)
            .fontColor('#CCCCCC')
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.albums, (album: AlbumViewModel) => {
            ListItem() {
              this.FavoriteCard(album)
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onReachEnd(() => this.loadMore())
      }
    }
      .width('100%')
      .height('100%')
      .backgroundColor('#F8F8F8')

      // ─── 新建文件夹弹窗 ───
      if (this.showFolderDialog) {
      Column() {
        Column() {
          Text('新建收藏夹')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 12 })

          TextInput({ placeholder: '请输入收藏夹名称', text: this.newFolderName })
            .width('100%')
            .height(40)
            .fontSize(14)
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => this.newFolderName = value)

          Row() {
            Button('取消')
              .fontSize(14)
              .fontColor('#999999')
              .backgroundColor('#F5F5F5')
              .borderRadius(8)
              .layoutWeight(1)
              .height(40)
              .onClick(() => this.showFolderDialog = false)

            Button('确定')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .backgroundColor('#FF5A5F')
              .borderRadius(8)
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => this.onConfirmAddFolder())
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('80%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .shadow({ radius: 12, color: '#20000000', offsetX: 0, offsetY: 4 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#60000000')
      .justifyContent(FlexAlign.Center)
        .position({ x: 0, y: 0 })
        .onClick(() => this.showFolderDialog = false)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  FavoriteCard(album: AlbumViewModel) {
    Row() {
      // 封面图
      Image(album.coverUrl)
        .width(90)
        .aspectRatio(0.72)
        .objectFit(ImageFit.Cover)
        .borderRadius(6)
        .backgroundColor('#F0F0F0')

      // 信息区
      Column() {
        Text(album.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(20)

        Row() {
          Text(album.author)
            .fontSize(12)
            .fontColor('#999999')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Button({ type: ButtonType.Normal }) {
            Text('取消收藏')
              .fontSize(11)
              .fontColor('#FF5A5F')
          }
          .backgroundColor('#FFF0F0')
          .borderRadius(10)
          .height(28)
          .padding({ left: 10, right: 10 })
          .onClick(() => this.onToggleFavorite(album.id))
        }
        .width('100%')
        .margin({ top: 6 })

        if (album.description) {
          Text(album.description)
            .fontSize(11)
            .fontColor('#BBBBBB')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .height(130)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .margin({ bottom: 8 })
    .onClick(() => this.onAlbumClick(album))
  }
}
