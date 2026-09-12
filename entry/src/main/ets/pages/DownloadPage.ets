import { router } from '@kit.ArkUI';
import { DownloadService } from '../network/DownloadService';
import { DownloadTask, DownloadStatus } from '../models/Album';

/**
 * 下载管理页面
 * 展示下载队列、进度、支持暂停/继续/删除
 */
@Entry
@Component
struct DownloadPage {
  @State tasks: DownloadTask[] = [];
  @StorageProp('topSafeHeight') topSafeHeight: number = 0;
  @StorageProp('bottomSafeHeight') bottomSafeHeight: number = 0;
  private downloadService: DownloadService = new DownloadService();

  async aboutToAppear(): Promise<void> {
    await this.downloadService.initCache();
    this.tasks = this.downloadService.getTasks();
    // 注册回调，任务状态变化时刷新 UI
    this.downloadService.onTaskUpdated = () => {
      this.tasks = this.downloadService.getTasks();
    };
  }

  aboutToDisappear(): void {
    this.downloadService.onTaskUpdated = null;
  }

  onBack(): void {
    router.back();
  }

  onPause(taskId: string): void {
    this.downloadService.pauseTask(taskId);
  }

  onResume(taskId: string): void {
    this.downloadService.resumeTask(taskId);
  }

  onDelete(taskId: string): void {
    this.downloadService.removeTask(taskId);
  }

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

  // 格式化文件大小
  formatSize(count: number): string {
    return `${count} 张`;
  }

  build() {
    Column() {
      // ── 顶部标题栏 ──
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('←')
            .fontSize(20)
            .fontColor($r('app.color.text_primary'))
        }
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .onClick(() => this.onBack())

        Text('下载管理')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        // 占位保持平衡
        Row().width(40).height(40)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor($r('app.color.bg_card'))

      Divider().height(1).color($r('app.color.divider'))

      // ── 统计 ──
      Row() {
        Text(`共 ${this.tasks.length} 个任务`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 8, bottom: 4 })
      .backgroundColor($r('app.color.bg_card'))

      // ── 下载列表 ──
      if (this.tasks.length === 0) {
        Column() {
          Text('暂无下载任务')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'))
          Text('在专辑详情页点击章节旁的下载按钮添加任务')
            .fontSize(13)
            .fontColor($r('app.color.text_disabled'))
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.tasks, (task: DownloadTask) => {
            ListItem() {
              this.TaskCard(task)
            }
          }, (item: DownloadTask) => item.taskId)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page_alt'))
  }

  @Builder
  TaskCard(task: DownloadTask) {
    Column() {
      Row() {
        Column() {
          // 标题行
          Row() {
            Text(task.chapterName)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            Text(task.getStatusText())
              .fontSize(12)
              .fontColor(this.getStatusColor(task.status))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .backgroundColor(this.getStatusBgColor(task.status))
              .borderRadius(4)
          }
          .width('100%')

          // 所属专辑
          Text(task.albumName)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 进度条
          if (task.status === DownloadStatus.DOWNLOADING || task.status === DownloadStatus.PAUSED) {
            Column() {
              Row() {
                Text(`${task.completedImages}/${task.totalImages}`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))

                Text(`${task.getProgress()}%`)
                  .fontSize(11)
                  .fontColor(this.getProgressColor(task.status))
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .margin({ top: 6, bottom: 4 })

              Progress({
                value: task.getProgress(),
                type: ProgressType.Linear,
              })
                .width('100%')
                .height(4)
                .color(this.getProgressColor(task.status))
                .backgroundColor($r('app.color.bg_placeholder'))
            }
            .width('100%')
          } else if (task.status === DownloadStatus.DONE) {
            Text(`共 ${task.totalImages} 张图片`)
              .fontSize(11)
              .fontColor($r('app.color.status_done'))
              .margin({ top: 6 })
          } else if (task.status === DownloadStatus.ERROR) {
            Text(task.errorMsg || '下载失败')
              .fontSize(11)
              .fontColor($r('app.color.brand'))
              .margin({ top: 6 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // ── 操作按钮 ──
        Column() {
          if (task.status === DownloadStatus.DOWNLOADING) {
            Button({ type: ButtonType.Normal }) {
              Text('暂停')
                .fontSize(11)
                .fontColor($r('app.color.status_wait'))
            }
            .backgroundColor($r('app.color.status_wait_bg'))
            .borderRadius(4)
            .height(28)
            .padding({ left: 10, right: 10 })
            .onClick(() => this.onPause(task.taskId))
          } else if (task.status === DownloadStatus.PAUSED || task.status === DownloadStatus.ERROR) {
            Button({ type: ButtonType.Normal }) {
              Text('继续')
                .fontSize(11)
                .fontColor($r('app.color.status_done'))
            }
            .backgroundColor($r('app.color.status_done_bg'))
            .borderRadius(4)
            .height(28)
            .padding({ left: 10, right: 10 })
            .onClick(() => this.onResume(task.taskId))
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
          .margin({ top: 6 })
          .onClick(() => this.onDelete(task.taskId))
        }
        .margin({ left: 12 })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(8)
    .margin({ bottom: 8 })
  }
}
