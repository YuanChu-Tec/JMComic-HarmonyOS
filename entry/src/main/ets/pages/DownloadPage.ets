import { common } from '@kit.AbilityKit';
import { navPop } from '../common/NavHelper';
import { DownloadService } from '../network/DownloadService';
import { ApiService } from '../network/ApiService';
import { DownloadTask, DownloadStatus } from '../models/Album';
import { ZipExporter, AlbumExportRef } from '../common/ZipExporter';
import { CacheManager } from '../common/CacheManager';
import { HAIRLINE_BORDER } from '../common/UiEffects';

/** 下载列表按专辑分组（专辑按状态档位排序：待导出>下载中>等待下载>下载失败>已导出，同档内最近添加倒序） */
interface AlbumGroup {
  albumId: number;
  albumName: string;
  tasks: DownloadTask[];
  /** 专辑是否已导出过压缩包（导出成功标记；新增章节任务时重置） */
  exported: boolean;
  /** 全部章节图片总数 */
  totalPages: number;
}

/**
 * 下载管理页面（专辑卡片式）
 *
 * - 卡片：封面缩略 + 完整标题 + 「x/y 章 · N 页 · 状态」统计行 + 导出/删除操作
 * - 筛选栏：全部 / 未导出 / 已导出（带计数）
 * - 点卡片正文展开章节明细（进度条、暂停/继续/删除）
 * - 「管理」进入多选模式：全选 / 批量导出 / 批量删除（删除连带清理本地文件）
 * - 导出经 ZipExporter 由用户在系统保存对话框选位置，成功后标记专辑"已导出"
 */
@Component
struct DownloadPage {
  @State groups: AlbumGroup[] = [];
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  /** 筛选：all | not_exported | exported */
  @State filter: string = 'all';
  /** 管理多选模式 */
  @State manageMode: boolean = false;
  @State selectedIds: Set<string> = new Set<string>();
  /** 展开章节明细的专辑 ID；-1 表示全部收起 */
  @State expandedAlbumId: number = -1;
  /** 正在导出的专辑 ID：-1 无；-2 管理态批量导出中（防重复触发 + 卡片按钮定向转圈） */
  @State exportingAlbumId: number = -1;
  private downloadService: DownloadService | null = null;
  private cache: CacheManager | null = null;
  private apiService: ApiService = ApiService.getInstance();

  async aboutToAppear(): Promise<void> {
    this.downloadService = await DownloadService.getInstance();
    this.cache = await CacheManager.getInstance();
    // 注册回调，任务状态变化时刷新 UI
    this.downloadService.onTaskUpdated = () => this.refreshGroups();
    this.refreshGroups();
  }

  aboutToDisappear(): void {
    if (this.downloadService) {
      this.downloadService.onTaskUpdated = null;
    }
  }

  onBack(): void {
    navPop();
  }

  /** 从服务取最新任务并按专辑重建分组（含导出状态与页数统计） */
  private refreshGroups(): void {
    if (!this.downloadService) return;
    let tasks = this.downloadService.getTasks();
    let map: Map<number, AlbumGroup> = new Map();
    for (let t of tasks) {
      let g = map.get(t.albumId);
      if (!g) {
        g = {
          albumId: t.albumId,
          albumName: t.albumName,
          tasks: [],
          exported: this.cache?.isAlbumExported(t.albumId) ?? false,
          totalPages: 0
        } as AlbumGroup;
        map.set(t.albumId, g);
      }
      g.tasks.push(t);
      g.totalPages += t.totalImages;
    }
    let list: AlbumGroup[] = Array.from(map.values());
    // 排序口径（2026-11-26）：待导出 > 下载中 > 等待下载 > 下载失败 > 已导出；
    // 同档内按最近添加时间倒序
    list.sort((a: AlbumGroup, b: AlbumGroup): number => {
      let ra = this.groupStatusRank(a);
      let rb = this.groupStatusRank(b);
      if (ra !== rb) {
        return ra - rb;
      }
      let ta = a.tasks.length > 0 ? a.tasks[a.tasks.length - 1].addTime : 0;
      let tb = b.tasks.length > 0 ? b.tasks[b.tasks.length - 1].addTime : 0;
      return tb - ta;
    });
    this.groups = list;
    // 管理态下清理已消失的选中项
    if (this.manageMode) {
      let alive: Set<string> = new Set<string>();
      for (let g of list) {
        alive.add(String(g.albumId));
      }
      let next: Set<string> = new Set<string>();
      this.selectedIds.forEach((id: string) => {
        if (alive.has(id)) {
          next.add(id);
        }
      });
      this.selectedIds = next;
    }
  }

  // ─── 分组派生信息 ───

  private groupDoneCount(g: AlbumGroup): number {
    let n = 0;
    for (let t of g.tasks) {
      if (t.status === DownloadStatus.DONE) n++;
    }
    return n;
  }

  private groupHasDone(g: AlbumGroup): boolean {
    return this.groupDoneCount(g) > 0;
  }

  /**
   * 专辑级状态归类（与排序档位一一对应）：
   * 0 待导出（全部完成未导出）/ 1 下载中 / 2 等待下载（排队或暂停，重启恢复的任务也在此）
   * / 3 下载失败 / 4 已导出。判定顺序即优先级：活跃态 > 暂停态 > 失败态 > 终态。
   */
  private groupStatusRank(g: AlbumGroup): number {
    let hasError = false;
    let hasWaiting = false;
    let allDone = true;
    for (let t of g.tasks) {
      if (t.status === DownloadStatus.DOWNLOADING) return 1;
      if (t.status === DownloadStatus.QUEUED || t.status === DownloadStatus.PAUSED) hasWaiting = true;
      if (t.status === DownloadStatus.ERROR) hasError = true;
      if (t.status !== DownloadStatus.DONE) allDone = false;
    }
    if (hasWaiting) return 2;
    if (hasError) return 3;
    if (allDone) return g.exported ? 4 : 0;
    return 3;
  }

  /** 统计行第三段状态文案：五档归类文案（待导出/下载中/等待下载/下载失败/已导出） */
  private groupStatusText(g: AlbumGroup): string {
    switch (this.groupStatusRank(g)) {
      case 0: return '待导出';
      case 1: return '下载中';
      case 2: return '等待下载';
      case 3: return '下载失败';
      default: return '已导出';
    }
  }

  private groupStatusColor(g: AlbumGroup): Resource {
    switch (this.groupStatusRank(g)) {
      case 0: return $r('app.color.status_done');
      case 1: return $r('app.color.status_downloading');
      case 2: return $r('app.color.status_wait');
      case 3: return $r('app.color.brand');
      default: return $r('app.color.text_tertiary');
    }
  }

  private notExportedCount(): number {
    let n = 0;
    for (let g of this.groups) {
      if (!g.exported) n++;
    }
    return n;
  }

  private exportedCount(): number {
    let n = 0;
    for (let g of this.groups) {
      if (g.exported) n++;
    }
    return n;
  }

  private filteredGroups(): AlbumGroup[] {
    if (this.filter === 'not_exported') {
      return this.groups.filter((g: AlbumGroup): boolean => !g.exported);
    }
    if (this.filter === 'exported') {
      return this.groups.filter((g: AlbumGroup): boolean => g.exported);
    }
    return this.groups;
  }

  // ─── 交互 ───

  private onCardTap(group: AlbumGroup): void {
    if (this.manageMode) {
      this.toggleSelect(group.albumId);
      return;
    }
    // 点卡片正文展开/收起章节明细
    if (this.expandedAlbumId === group.albumId) {
      this.expandedAlbumId = -1;
    } else {
      this.expandedAlbumId = group.albumId;
    }
  }

  private toggleSelect(albumId: number): void {
    let key = String(albumId);
    let next = new Set<string>(this.selectedIds);
    if (next.has(key)) {
      next.delete(key);
    } else {
      next.add(key);
    }
    this.selectedIds = next;
  }

  private toggleManageMode(): void {
    if (this.manageMode) {
      this.selectedIds = new Set<string>();
    }
    this.manageMode = !this.manageMode;
    this.expandedAlbumId = -1;
  }

  private selectAllVisible(): void {
    let next = new Set<string>();
    for (let g of this.filteredGroups()) {
      next.add(String(g.albumId));
    }
    this.selectedIds = next;
  }

  /** Toast 统一走 UIContext 形态（开发规范 §5.5，禁模块级 promptAction 直呼） */
  private showToast(message: string, duration: number = 2000): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: duration });
  }

  /** 确认弹窗（统一走 UIContext 形态）：返回是否点击了确认键 */
  private async confirmDialog(title: string, message: string, confirmText: string): Promise<boolean> {
    try {
      let result = await this.getUIContext().getPromptAction().showDialog({
        title: title,
        message: message,
        buttons: [
          { text: '取消', color: '#999999' },
          { text: confirmText, color: '#FF5A5F' }
        ]
      });
      return result.index === 1;
    } catch (err) {
      console.warn('[DownloadPage] dialog dismissed:', JSON.stringify(err));
      return false;
    }
  }

  /** 导出单个专辑压缩包，成功后标记"已导出" */
  async onExportAlbum(group: AlbumGroup): Promise<void> {
    if (this.exportingAlbumId !== -1) return;
    this.exportingAlbumId = group.albumId;
    this.showToast('正在打包压缩包，请稍候…', 3000);
    try {
      let context = getContext() as common.UIAbilityContext;
      let msg = await ZipExporter.exportAlbum(context, group.albumId, group.albumName);
      if (msg === null) {
        return; // 用户取消保存，不打标
      }
      this.cache?.setAlbumExported(group.albumId, true);
      // 设置开启时清理本地下载文件（仅保留下载记录）
      let autoDelete = this.cache?.isAutoDeleteAfterExport() ?? false;
      if (autoDelete) {
        this.downloadService?.deleteAlbumFiles(group.albumId, group.albumName);
      }
      this.refreshGroups();
      this.showToast(autoDelete ? `${msg}，本地缓存已清理` : msg, 4000);
    } catch (e) {
      console.error('[DownloadPage] export album error:', JSON.stringify(e));
      this.showToast(`导出失败：${(e as Error).message || '未知错误'}`, 4000);
    } finally {
      this.exportingAlbumId = -1;
    }
  }

  /** 管理态批量导出选中的专辑 */
  async onExportSelected(): Promise<void> {
    if (this.exportingAlbumId !== -1) return;
    let refs: AlbumExportRef[] = [];
    for (let g of this.groups) {
      if (this.selectedIds.has(String(g.albumId)) && this.groupHasDone(g)) {
        refs.push({ albumId: g.albumId, albumName: g.albumName } as AlbumExportRef);
      }
    }
    if (refs.length === 0) {
      this.showToast('选中项中没有已下载内容');
      return;
    }
    this.exportingAlbumId = -2;
    this.showToast(`正在打包 ${refs.length} 个压缩包，请稍候…`, 3000);
    try {
      let context = getContext() as common.UIAbilityContext;
      let msg = await ZipExporter.exportAlbums(context, refs);
      if (msg === null) {
        return;
      }
      for (let r of refs) {
        this.cache?.setAlbumExported(r.albumId, true);
      }
      // 设置开启时清理本地下载文件（仅保留下载记录）
      let autoDelete = this.cache?.isAutoDeleteAfterExport() ?? false;
      if (autoDelete) {
        for (let r of refs) {
          this.downloadService?.deleteAlbumFiles(r.albumId, r.albumName);
        }
      }
      this.refreshGroups();
      this.showToast(autoDelete ? `${msg}，本地缓存已清理` : msg, 4000);
    } catch (e) {
      console.error('[DownloadPage] export selected error:', JSON.stringify(e));
      this.showToast(`导出失败：${(e as Error).message || '未知错误'}`, 4000);
    } finally {
      this.exportingAlbumId = -1;
    }
  }

  /** 删除单个专辑（任务记录 + 本地文件） */
  async onDeleteAlbum(group: AlbumGroup): Promise<void> {
    let ok = await this.confirmDialog('删除下载',
      `将删除《${group.albumName}》的下载任务与已下载文件，已导出的压缩包不受影响。`, '删除');
    if (!ok) return;
    this.downloadService?.deleteAlbumTasks(group.albumId, group.albumName);
    this.cache?.setAlbumExported(group.albumId, false);
    if (this.expandedAlbumId === group.albumId) {
      this.expandedAlbumId = -1;
    }
    this.refreshGroups();
    this.showToast('已删除', 2000);
  }

  /** 管理态批量删除选中专辑 */
  async onDeleteSelected(): Promise<void> {
    let count = this.selectedIds.size;
    if (count === 0) {
      this.showToast('请先选择要删除的专辑');
      return;
    }
    let ok = await this.confirmDialog('批量删除',
      `将删除选中的 ${count} 部漫画的下载任务与已下载文件，已导出的压缩包不受影响。`, '删除');
    if (!ok) return;
    for (let g of this.groups) {
      if (this.selectedIds.has(String(g.albumId))) {
        this.downloadService?.deleteAlbumTasks(g.albumId, g.albumName);
        this.cache?.setAlbumExported(g.albumId, false);
      }
    }
    this.selectedIds = new Set<string>();
    this.refreshGroups();
    this.showToast(`已删除 ${count} 部`, 2000);
  }

  // ─── UI ───

  build() {
    NavDestination() {
      Column() {
        // ── 顶部标题栏：返回 | 标题 | 管理 ──
        Row() {
          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor($r('app.color.overlay_bg'))
          .border(HAIRLINE_BORDER)
          .onClick(() => this.onBack())

          Text('下载管理')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Row() {
            Text(this.manageMode ? '取消' : '管理')
              .fontSize(15)
              .fontColor(this.manageMode ? $r('app.color.brand') : $r('app.color.text_secondary'))
          }
          .width(44)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .onClick(() => this.toggleManageMode())
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: this.topSafeHeight + 4, bottom: 4 })
        .backgroundColor($r('app.color.bg_card'))

        Divider().height(1).color($r('app.color.divider'))

        // ── 筛选栏：全部 / 未导出 / 已导出（内联绑定，计数随 groups 重赋值即时刷新；
        //    不能抽成 @Builder——按值传参的状态变化不会触发 Builder 内刷新） ──
        Row() {
          Text(`全部 ${this.groups.length}`)
            .fontSize(13)
            .fontColor(this.filter === 'all' ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.filter === 'all' ? $r('app.color.brand') : $r('app.color.bg_card'))
            .borderRadius(15)
            .margin({ right: 8 })
            .onClick(() => {
              this.filter = 'all';
            })

          Text(`未导出 ${this.notExportedCount()}`)
            .fontSize(13)
            .fontColor(this.filter === 'not_exported' ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.filter === 'not_exported' ? $r('app.color.brand') : $r('app.color.bg_card'))
            .borderRadius(15)
            .margin({ right: 8 })
            .onClick(() => {
              this.filter = 'not_exported';
            })

          Text(`已导出 ${this.exportedCount()}`)
            .fontSize(13)
            .fontColor(this.filter === 'exported' ? $r('app.color.text_on_accent') : $r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.filter === 'exported' ? $r('app.color.brand') : $r('app.color.bg_card'))
            .borderRadius(15)
            .margin({ right: 8 })
            .onClick(() => {
              this.filter = 'exported';
            })

          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 6 })

        // ── 专辑卡片列表 ──
        if (this.filteredGroups().length === 0) {
          Column() {
            Text(this.filter === 'all' ? '暂无下载任务' : '该分类下暂无专辑')
              .fontSize(16)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.filter === 'all' ? '在漫画详情页点击「下载」加入下载队列' : '切换筛选或先去下载')
              .fontSize(13)
              .fontColor($r('app.color.text_disabled'))
              .margin({ top: 6 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.filteredGroups(), (group: AlbumGroup) => {
              ListItem() {
                this.AlbumCard(group)
              }
            }, (group: AlbumGroup) =>
              `${group.albumId}|${this.expandedAlbumId === group.albumId ? 1 : 0}` +
              `|${this.manageMode ? 1 : 0}|${this.selectedIds.has(String(group.albumId)) ? 1 : 0}` +
              `|${this.groupDoneCount(group)}|${group.tasks.length}|${group.totalPages}|${group.exported ? 1 : 0}` +
              `|${this.exportingAlbumId === group.albumId ? 1 : 0}` +
              // 状态档位入 key：章节排队→下载中这类不改变计数的状态迁移也要触发卡片重渲染
              `|${this.groupStatusRank(group)}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ left: 16, right: 16, bottom: this.manageMode ? 0 : this.bottomSafeHeight + 20 })
        }

        // ── 管理态底部操作栏 ──
        if (this.manageMode && this.groups.length > 0) {
          Row() {
            Text('全选')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .onClick(() => this.selectAllVisible())

            Blank()

            if (this.selectedExportableCount() > 0) {
              Text(`导出(${this.selectedExportableCount()})`)
                .fontSize(14)
                .fontColor($r('app.color.brand'))
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .margin({ right: 8 })
                .onClick(() => this.onExportSelected())
            }

            Text(`删除(${this.selectedIds.size})`)
              .fontSize(14)
              .fontColor($r('app.color.brand'))
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .onClick(() => this.onDeleteSelected())
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 6, bottom: this.bottomSafeHeight + 6 })
          .backgroundColor($r('app.color.bg_card'))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page_alt'))
    }
    .hideTitleBar(true)
  }

  /** 专辑卡片：封面缩略 + 完整标题 + 统计行 + 导出/删除 */
  @Builder
  AlbumCard(group: AlbumGroup) {
    Column() {
      Row() {
        // 封面缩略（管理态选中时叠暗化勾选遮罩）
        Stack() {
          Image(this.apiService.buildCoverUrl(group.albumId))
            .width(64)
            .height(86)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor($r('app.color.bg_secondary'))

          if (this.manageMode && this.selectedIds.has(String(group.albumId))) {
            Column() {
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(26)
                .fontColor([$r('app.color.text_on_accent')])
            }
            .width(64)
            .height(86)
            .borderRadius(8)
            .backgroundColor('#8C000000')
            .justifyContent(FlexAlign.Center)
          }
        }
        .width(64)
        .height(86)

        Column() {
          // 完整标题（最多两行）
          Text(group.albumName)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(20)

          // 统计行：x/y 章 · N 页 · 状态（进行中为下载状态，完成后突出导出状态）
          Text(`${this.groupDoneCount(group)}/${group.tasks.length} 章 · ${group.totalPages} 页 · ${this.groupStatusText(group)}`)
            .fontSize(12)
            .fontColor(this.groupStatusColor(group))
            .margin({ top: 6 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 操作行：导出 + 删除
          Row() {
            if (this.groupHasDone(group)) {
              Button({ type: ButtonType.Normal }) {
                Row() {
                  if (this.exportingAlbumId === group.albumId) {
                    LoadingProgress()
                      .width(13)
                      .height(13)
                      .color($r('app.color.brand'))
                  } else if (group.exported) {
                    SymbolGlyph($r('sys.symbol.checkmark_circle'))
                      .fontSize(13)
                      .fontColor([$r('app.color.text_tertiary')])
                  } else {
                    SymbolGlyph($r('sys.symbol.arrow_down'))
                      .fontSize(13)
                      .fontColor([$r('app.color.brand')])
                  }
                  Text(group.exported ? '已导出' : '导出')
                    .fontSize(12)
                    .fontColor(group.exported ? $r('app.color.text_tertiary') : $r('app.color.brand'))
                    .margin({ left: 4 })
                }
                .alignItems(VerticalAlign.Center)
              }
              .backgroundColor(group.exported ? $r('app.color.bg_secondary') : $r('app.color.brand_bg'))
              .borderRadius(15)
              .height(30)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                if (!this.manageMode) {
                  this.onExportAlbum(group);
                }
              })
            }

            Blank()

            Stack() {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(18)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width(36)
            .height(36)
            .onClick(() => {
              if (!this.manageMode) {
                this.onDeleteAlbum(group);
              }
            })
          }
          .width('100%')
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .margin({ left: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.onCardTap(group))

      // 展开章节明细（非管理态）
      if (!this.manageMode && this.expandedAlbumId === group.albumId) {
        Divider()
          .height(1)
          .color($r('app.color.divider'))
          .margin({ top: 10 })

        ForEach(group.tasks, (task: DownloadTask) => {
          ChapterRow({
            task: task,
            onPauseClick: (taskId: string): void => this.onPause(taskId),
            onResumeClick: (taskId: string): void => this.onResume(taskId),
            onDeleteClick: (taskId: string): void => {
              this.onDeleteChapter(taskId);
            }
          })
        }, (task: DownloadTask) => task.taskId)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ top: 8 })
  }

  private selectedExportableCount(): number {
    let n = 0;
    for (let g of this.groups) {
      if (this.selectedIds.has(String(g.albumId)) && this.groupHasDone(g)) {
        n++;
      }
    }
    return n;
  }

  onPause(taskId: string): void {
    this.downloadService?.pauseTask(taskId);
  }

  onResume(taskId: string): void {
    this.downloadService?.resumeTask(taskId);
  }

  /** 删除章节任务记录（弹窗确认；已下载文件保留，仍随专辑导出） */
  async onDeleteChapter(taskId: string): Promise<void> {
    let task = this.downloadService?.getTasks().find((t: DownloadTask): boolean => t.taskId === taskId) ?? null;
    let chapterName = task?.chapterName || '该章节';
    let ok = await this.confirmDialog('删除章节任务',
      `将删除「${chapterName}」的下载任务记录，已下载的图片文件保留（仍会随专辑导出）。`, '删除');
    if (!ok) return;
    this.downloadService?.removeTask(taskId);
  }
}

/** 单章节任务行：@ObjectLink 绑定被观察任务实例，服务层对进度/状态的修改驱动本行自动刷新 */
@Component
struct ChapterRow {
  @ObjectLink task: DownloadTask;
  onPauseClick: (taskId: string) => void = (_taskId: string) => {};
  onResumeClick: (taskId: string) => void = (_taskId: string) => {};
  onDeleteClick: (taskId: string) => void = (_taskId: string) => {};

  getProgressColor(status: DownloadStatus): Resource {
    switch (status) {
      case DownloadStatus.DOWNLOADING: return $r('app.color.status_done');
      case DownloadStatus.PAUSED: return $r('app.color.status_wait');
      case DownloadStatus.DONE: return $r('app.color.status_downloading');
      case DownloadStatus.ERROR: return $r('app.color.brand');
      default: return $r('app.color.text_disabled');
    }
  }

  getStatusColor(status: DownloadStatus): Resource {
    switch (status) {
      case DownloadStatus.DOWNLOADING: return $r('app.color.status_done');
      case DownloadStatus.PAUSED: return $r('app.color.status_wait');
      case DownloadStatus.DONE: return $r('app.color.status_downloading');
      case DownloadStatus.ERROR: return $r('app.color.brand');
      default: return $r('app.color.text_tertiary');
    }
  }

  /** 状态标签的淡色背景 */
  getStatusBgColor(status: DownloadStatus): Resource {
    switch (status) {
      case DownloadStatus.DOWNLOADING: return $r('app.color.status_done_bg');
      case DownloadStatus.PAUSED: return $r('app.color.status_wait_bg');
      case DownloadStatus.DONE: return $r('app.color.status_downloading_bg');
      case DownloadStatus.ERROR: return $r('app.color.brand_bg');
      default: return $r('app.color.bg_secondary');
    }
  }

  build() {
    Row() {
      Column() {
        // 章节名
        Text(this.task.chapterName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 进度条（下载中/暂停）
        if (this.task.status === DownloadStatus.DOWNLOADING || this.task.status === DownloadStatus.PAUSED) {
          Column() {
            Row() {
              Text(`${this.task.completedImages}/${this.task.totalImages}`)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))

              Text(`${this.task.getProgress()}%`)
                .fontSize(11)
                .fontColor(this.getProgressColor(this.task.status))
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({ top: 5, bottom: 3 })

            Progress({
              value: this.task.getProgress(),
              type: ProgressType.Linear,
            })
              .width('100%')
              .height(4)
              .color(this.getProgressColor(this.task.status))
              .backgroundColor($r('app.color.bg_placeholder'))
          }
          .width('100%')
        } else if (this.task.status === DownloadStatus.DONE) {
          Text(`共 ${this.task.totalImages} 张图片`)
            .fontSize(11)
            .fontColor($r('app.color.status_done'))
            .margin({ top: 4 })
        } else if (this.task.status === DownloadStatus.ERROR) {
          Text(this.task.errorMsg || '下载失败')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .margin({ top: 4 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // ── 状态 + 操作胶囊（统一 28 高度/圆角/淡色底，视觉成套） ──
      Row() {
        Row() {
          Text(this.task.getStatusText())
            .fontSize(11)
            .fontColor(this.getStatusColor(this.task.status))
        }
        .height(28)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 10, right: 10 })
        .backgroundColor(this.getStatusBgColor(this.task.status))
        .borderRadius(4)

        if (this.task.status === DownloadStatus.DOWNLOADING) {
          Button({ type: ButtonType.Normal }) {
            Text('暂停')
              .fontSize(11)
              .fontColor($r('app.color.status_wait'))
          }
          .backgroundColor($r('app.color.status_wait_bg'))
          .borderRadius(4)
          .height(28)
          .padding({ left: 10, right: 10 })
          .margin({ left: 6 })
          .onClick(() => this.onPauseClick(this.task.taskId))
        } else if (this.task.status === DownloadStatus.PAUSED || this.task.status === DownloadStatus.ERROR) {
          Button({ type: ButtonType.Normal }) {
            Text('继续')
              .fontSize(11)
              .fontColor($r('app.color.status_done'))
          }
          .backgroundColor($r('app.color.status_done_bg'))
          .borderRadius(4)
          .height(28)
          .padding({ left: 10, right: 10 })
          .margin({ left: 6 })
          .onClick(() => this.onResumeClick(this.task.taskId))
        }

        Button({ type: ButtonType.Normal }) {
          Text('删除')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
        }
        .backgroundColor($r('app.color.brand_bg'))
        .borderRadius(4)
        .height(28)
        .padding({ left: 10, right: 10 })
        .margin({ left: 6 })
        .onClick(() => this.onDeleteClick(this.task.taskId))
      }
      .margin({ left: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10 })
  }
}

/**
 * 系统路由表入口（router_map.json 的 buildFunction），函数名须与配置完全一致
 */
@Builder
export function DownloadPageBuilder() {
  DownloadPage();
}
