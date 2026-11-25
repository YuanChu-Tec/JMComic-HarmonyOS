# JMComic-HarmonyOS

<p align="center">
  <h3 align="center">JMComic for HarmonyOS</h3>
  <p align="center">
    基于 ArkTS 的 JMComic（禁漫天堂）客户端 — 为鸿蒙系统提供原生、流畅的漫画浏览体验。
  </p>

## 目录

- [声明](#声明)
- [项目简介](#项目简介)
- [功能特性](#功能特性)
- [项目架构总览](#项目架构总览)
- [技术栈](#技术栈)
- [模块目录说明](#模块目录说明)
- [核心模块深度解析](#核心模块深度解析)
- [数据流](#数据流)
- [权限说明](#权限说明)
- [构建配置](#构建配置)
- [安装调试](#安装调试)
- [开发指引](#开发指引)
- [反馈](#反馈)
- [许可证](#许可证)

---

## 声明

本仓库的所有内容仅供学习交流使用。如果您认为该内容侵犯了您的权益，请在 issue 中与我们联系，我们将立即删除相关内容。

## 项目简介

JMComic-HarmonyOS 是基于 **ArkTS / ArkUI** 构建的 **HarmonyOS 漫画客户端**，包名 `com.YuanChu.JMComic`，目标设备覆盖手机、平板、2in1、车机、穿戴、TV。项目从 JMComic 的 Python / Java / QT 生态移植而来，完整复刻了核心数据链路（API 加解密、图片 scramble 解码、域名故障转移等）。

| 属性 | 值 |
|------|-----|
| 包名 | com.YuanChu.JMComic |
| 版本 | 1.1.0 (versionCode: 1010000) |
| 最低兼容 SDK | 6.1.1(24) |
| 目标 SDK | 26.0.0 |
| 应用类型 | Stage 模型 + ArkTS |
| 许可证 | GPL-3.0 |

核心技术选型：

- **UI 框架** — ArkUI 声明式 UI（`@Component` / `@State` / `@StorageProp`），HdsTabs 悬浮页签
- **页面路由** — Navigation + NavPathStack，子页经系统路由表 `router_map.json` 注册
- **网络层** — `@kit.NetworkKit` http，封装 Cookie 会话管理与失败重试
- **域名管理** — 多 API / 图片 CDN 域名故障转移，失败计数 + 并行探活 + 定期复探
- **加密体系** — MD5 Token 签名 + AES-256-ECB 响应数据解密（`@kit.CryptoArchitectureKit`）
- **图片解码** — scramble 分割还原算法（TaskPool 并行），统一图片仓库 + 视口预加载
- **持久化** — RDB（relationalStore）存漫画实体、列表顺序、阅读进度与账号；Preferences 已移除
- **图片存储** — ComicLibrary 统一仓库，阅读 / 下载 / 导出共用一份 PNG，逐页原子替换
- **分享与导出** — 系统分享（ShareKit）、通知栏下载进度（NotificationKit）、ZIP 导出（zlib + DocumentViewPicker）

---

## 功能特性

- **首页**：最新上传 + 推荐分区横向滑动；分区「更多」页首屏复用首页数据，触底继续加载
- **分类浏览**：同人 / 单本 / 短篇 / 韩漫 / 美漫 / Cosplay / 3D / 英文站，支持多种排序（最新、最多观看、最多图片、月/周/日排行）
- **搜索**：关键词搜索 + 无上限搜索历史（长列表可滚动）
- **漫画详情**：作者、标签、系列（章节）列表、相关作品，收藏夹管理；本地优先渲染 + 下拉刷新
- **图片阅读器**：
  - 整本竖排拼接滚动，支持双指缩放（0.5x ~ 3.0x）
  - scramble 加密图片自动解码还原
  - 视口 ±10 项预加载 + 磁盘 PNG 缓存，滑动不白屏
  - 章节阅读进度自动记录，返回列表显示「看过」标记
  - 三种阅读模式一键切换：竖向滚动 / 横向翻页（左→右，西漫）/ 横向翻页（右→左，日漫），底部箭头按钮带旋转动画指示当前方向，并记忆上次选择
  - 横向翻页模式进入即定位到上次阅读页（基于 Swiper 初始索引瞬跳，无逐页滑动）
  - 底栏滑杆直接跳页，页码可拖到末页
- **收藏与历史**：收藏夹分组、观看历史自动同步，支持批量删除观看记录
- **登录与账号**：账号密码登录、记住密码与自动登录；多账号列表 / 切换 / 退出；冷启动先用本地会话快照点亮登录态，再静默复验
- **下载管理**：章节任务队列（暂停 / 继续 / 删除），按专辑分组并可按「全部 / 未导出 / 已导出」筛选；管理态支持全选、批量导出、批量删除；通知栏展示下载进度
- **导出**：把专辑图片打包为 ZIP，经系统保存对话框选择落盘位置
- **设置**：黑白模式、字段 / 封面 / 章节图片各自的重建间隔、图片仓库占用与清空、阅读缓存 / 已导出内容保留天数（按整部漫画清理，阅读记录保留）、清理缓存、清除阅读位置 / 已读记录
- **讨论区**：评论浏览、多模式筛选、登录后回复
- **分享与更新**：系统分享面板分享漫画详情；启动时检查 GitHub Release 新版本
- **本地优先**：列表、详情、评论先读本地库渲染，同时联网拉最新；字段 / 封面 / 章节图片各自按设置的间隔重建

---

## 项目架构总览

```
JMComic/
├── AppScope/                              # 应用级配置与全局资源
│   ├── app.json5                          # bundleName / version / icon
│   └── resources/                         # 应用图标（layered_image）
├── common/                                # 共享 HAR 模块
│   └── src/main/ets/utils/
│       └── DeviceUtils.ets                # 设备工具（模拟器判断）
├── entry/                                 # 主入口模块（HAP）
│   ├── src/main/ets/
│   │   ├── entryability/
│   │   │   └── EntryAbility.ets           # UIAbility 生命周期、沉浸式窗口、安全区
│   │   ├── entrybackupability/
│   │   │   └── EntryBackupAbility.ets     # 应用备份扩展
│   │   ├── pages/                         # 页面层（1 个 @Entry + 10 个 NavDestination）
│   │   │   ├── Index.ets                  # 唯一 @Entry：Navigation 根容器 + 四 Tab + 顶部栏
│   │   │   ├── SearchPage.ets             # 搜索页
│   │   │   ├── AlbumDetailPage.ets        # 漫画详情页（分享 / 下载 / 通知）
│   │   │   ├── ImageViewerPage.ets        # 图片阅读器
│   │   │   ├── LoginPage.ets              # 登录页
│   │   │   ├── DownloadPage.ets           # 下载管理页（分组 / 筛选 / 导出）
│   │   │   ├── AlbumCommentPage.ets       # 评论区
│   │   │   ├── AboutPage.ets              # 关于 / 防失联 / 检查更新
│   │   │   ├── SettingsPage.ets           # 设置页
│   │   │   ├── AccountManagePage.ets      # 多账号管理
│   │   │   ├── SectionMorePage.ets        # 首页分区「更多」
│   │   │   └── JmAlbumCard.ets            # 列表卡片组件
│   │   ├── models/
│   │   │   ├── dto/ApiDto.ets             # 服务器契约 DTO（专辑 / 图片 / 评论）
│   │   │   ├── ComicAlbum.ets             # 漫画实体 + AlbumViewModel
│   │   │   ├── AlbumFeed.ets              # 列表顺序（feed / 分区 / id 序）
│   │   │   └── Album.ets                  # 运行时模型（下载任务 / 登录会话）
│   │   ├── network/
│   │   │   ├── ApiService.ets             # API 服务层（单例，全部接口封装）
│   │   │   ├── DomainManager.ets          # 域名故障转移
│   │   │   ├── HttpClient.ets             # HTTP 客户端（Cookie / 重试 / 体积上限）
│   │   │   └── DownloadService.ets        # 章节下载任务队列（单引擎）
│   │   ├── storage/
│   │   │   ├── AppDatabase.ets            # RDB 建库与 DDL
│   │   │   ├── AlbumDao.ets               # 漫画实体 / 章节
│   │   │   ├── FeedDao.ets                # 列表顺序
│   │   │   ├── ProgressDao.ets            # 阅读进度
│   │   │   ├── PageCacheDao.ets           # 分页响应快照（带 TTL）
│   │   │   ├── SettingDao.ets             # 开关与偏好
│   │   │   └── AccountDao.ets             # 已保存账号
│   │   └── common/
│   │       ├── Constants.ets              # 全局常量（域名 / 分类 / 密钥 / 端点）
│   │       ├── CryptoUtils.ets            # Token 签名 + AES 解密
│   │       ├── ImageDecodeUtils.ets       # scramble 图片解码
│   │       ├── ComicLibrary.ets           # 统一图片仓库（PNG / meta.json / 原子替换）
│   │       ├── CacheManager.ets           # RDB 缓存门面（列表 / 偏好 / 进度）
│   │       ├── AccountManager.ets         # 多账号 + 会话快照 + 自动登录
│   │       ├── DownloadNotifier.ets       # 下载进度通知（节流）
│   │       ├── ZipExporter.ets            # 专辑 ZIP 导出
│   │       ├── NavHelper.ets              # Navigation 跳转（push / replace / pop）
│   │       ├── RouteParams.ets            # 路由参数具名接口
│   │       ├── ThemeManager.ets           # 主题（跟随系统 / 浅色 / 深色）
│   │       ├── ThemeSetting.ets           # 设置页「黑白模式」组件
│   │       ├── UpdateManager.ets          # 版本检查（GitHub Release）
│   │       └── CommentItem.ets            # 评论项组件
│   └── src/main/resources/                # 资源（颜色 / 字符串 / 图片 / 深色主题 / 路由表）
└── hvigor/                                # Hvigor 构建配置
```

### 分层架构

```text
┌─────────────────────────────────────────────┐
│              UI Layer (Pages)                │
│   Index, SearchPage, AlbumDetailPage, ...   │
├─────────────────────────────────────────────┤
│            Service Layer                     │
│   ApiService / DownloadService / Account    │
├─────────────────────────────────────────────┤
│             Storage Layer                    │
│   AppDatabase / *Dao / CacheManager          │
├─────────────────────────────────────────────┤
│          Infrastructure Layer                │
│   HttpClient / DomainManager / ComicLibrary  │
├─────────────────────────────────────────────┤
│             Utils Layer                      │
│   CryptoUtils / ImageDecodeUtils / ...      │
├─────────────────────────────────────────────┤
│        HarmonyOS Kit（ArkUI / Network / ...）│
└─────────────────────────────────────────────┘
```

数据流向是「网络 → 表 → UI」：响应只落库，页面写完再读一次表，UI 不直接持有服务器对象。

---

## 技术栈

### 鸿蒙 Kit 套件

| Kit | 用途 |
|-----|------|
| `@kit.AbilityKit` | UIAbility 生命周期、getContext、wantAgent（通知点击跳转） |
| `@kit.ArkUI` | 声明式 UI 框架（@Component, @State, @StorageProp, Navigation, Tabs, Scroll） |
| `@kit.ArkTS` | 语言运行时、util（MD5 hex 转换）、taskpool（并行解码） |
| `@kit.NetworkKit` | HTTP 请求（@ohos.net.http） |
| `@kit.ArkData` | RDB（relationalStore）持久化、uniformTypeDescriptor（分享类型） |
| `@kit.CoreFileKit` | 文件 I/O（fileIo）、DocumentViewPicker（文件选择 / 保存） |
| `@kit.ImageKit` | 图片解码（PixelMap / ImageSource / ImagePacker） |
| `@kit.CryptoArchitectureKit` | MD5、AES-256-ECB（Token 与响应解密） |
| `@kit.BasicServicesKit` | 剪贴板（pasteboard）、设备信息（deviceInfo）、zlib（ZIP 导出）、BusinessError |
| `@kit.NotificationKit` | 通知栏下载进度（downloadTemplate） |
| `@kit.ShareKit` | 系统分享面板（ShareController） |
| `@kit.PerformanceAnalysisKit` | 日志（hilog） |
| `@kit.UIDesignKit` | HdsTabs 悬浮页签、hdsMaterial 材质 |

### 第三方依赖

项目仅依赖本地共享模块，无第三方 ohpm 运行时依赖：

| 库 | 类型 | 用途 | 来源 |
|----|------|------|------|
| common | HAR（本地模块） | 设备工具等跨模块共享代码 | `file:../common` |
| @ohos/hypium / @ohos/hamock | 测试框架 | 单元测试 | ohpm（devDependencies） |

---

## 模块目录说明

### pages/ — 页面层（1 个 @Entry + 10 个 NavDestination）

| 文件 | 功能 |
|------|------|
| `Index.ets` | 唯一 @Entry：Navigation 根容器 + HdsTabs 四个 Tab（首页 / 分类 / 讨论区 / 个人中心）；沉浸式顶部栏；线路选择半模态 |
| `SearchPage.ets` | 关键词搜索、搜索历史（无上限，长列表可滚动） |
| `AlbumDetailPage.ets` | 漫画详情：作者 / 标签 / 章节列表 / 收藏 / 分享 / 阅读进度，本地优先 + 下拉刷新 |
| `ImageViewerPage.ets` | 图片阅读器：整本拼接滚动、缩放、scramble 解码、预加载、进度追踪、滑杆跳页 |
| `LoginPage.ets` | 账号密码登录、记住密码、跳转账号管理 |
| `DownloadPage.ets` | 下载管理：按专辑分组、已导出筛选、管理态批量导出 / 删除 |
| `AlbumCommentPage.ets` | 评论区，本地优先 + 下拉刷新 |
| `AboutPage.ets` | 关于 / 防失联 / 版本检查 |
| `SettingsPage.ets` | 设置：主题、刷新间隔与范围、图片仓库与保留策略、清理缓存、清除阅读位置 / 已读记录 |
| `AccountManagePage.ets` | 多账号列表 / 切换 / 退出登录 |
| `SectionMorePage.ets` | 首页分区「更多」：首屏复用首页数据，触底续拉 |
| `JmAlbumCard.ets` | 列表卡片组件（首页 / 分类 / 搜索 / 收藏共用） |

### network/ — 网络层

| 文件 | 职责 |
|------|------|
| `HttpClient.ets` | HTTP 封装：全局 Cookie 管理（重要 Cookie 优先）、自动解析 Set-Cookie、失败重试、响应体积上限、BOM 清洗 |
| `DomainManager.ets` | 域名故障转移：失败计数、并行探活、定期复探（5 分钟）、全死降级、手动指定线路 |
| `ApiService.ets` | 单例 API 服务：Token 签名头、响应 AES 解密、全部业务接口（搜索 / 详情 / 章节 / 收藏 / 登录 / 评论 / 观看历史） |
| `DownloadService.ets` | 章节任务队列：单引擎后台下载、暂停 / 继续 / 删除、任务持久化恢复、委托 ComicLibrary 落盘 |

### storage/ — 持久化层

| 文件 | 职责 |
|------|------|
| `AppDatabase.ets` | RDB 建库与 DDL（album / chapter / feed / pref / page_cache / read_state / account 等表） |
| `AlbumDao.ets` | 漫画实体与章节目录的读写 |
| `FeedDao.ets` | 列表顺序（首页 / 分类 / 搜索 / 收藏） |
| `ProgressDao.ets` | 阅读进度与已读标记 |
| `PageCacheDao.ets` | 分页响应快照（带 TTL） |
| `SettingDao.ets` | 开关、偏好等键值项 |
| `AccountDao.ets` | 已保存账号 |

### common/ — 工具与组件层

| 文件 | 职责 |
|------|------|
| `Constants.ets` | 域名列表、图片 URL 模板、APP 密钥、分类 / 排序映射、HTTP Headers |
| `CryptoUtils.ets` | MD5 Token 计算、AES-256-ECB 响应解密（对应 Python JmCryptoTool） |
| `ImageDecodeUtils.ets` | scramble 分割数计算与图片还原解码（对应 Python JmImageTool） |
| `ComicLibrary.ets` | 统一图片仓库：PNG 落盘、meta.json 提交标记、原子替换、按天清理 |
| `CacheManager.ets` | RDB 门面：分页快照 TTL、偏好设置、阅读进度、搜索历史 |
| `AccountManager.ets` | 多账号、会话快照、自动登录开关 |
| `DownloadNotifier.ets` | 下载进度通知（按最小间隔节流） |
| `ZipExporter.ets` | 专辑 ZIP 打包与系统保存对话框导出 |
| `NavHelper.ets` | Navigation 跳转辅助（navPush / navReplace / navPop） |
| `RouteParams.ets` | 各页面路由参数的具名接口 |
| `ThemeManager.ets` / `ThemeSetting.ets` | 主题切换（跟随系统 / 浅色 / 深色）与设置项组件 |
| `UpdateManager.ets` | 读取本机版本、拉取 GitHub Release、比较版本 |
| `CommentItem.ets` | 评论项组件 |

### models/ — 数据模型

按「服务器契约 → 实体 → 列表顺序」分层，全部为纯类型 + 纯函数，不 import 数据库与文件系统：

| 文件 | 职责 |
|------|------|
| `dto/ApiDto.ets` | 服务器契约：`JmAlbumInfo` / `JmAlbumDetail` / `JmPhotoInfo` / `JmImageInfo` / `PictureData` / `JmPictureResp` / `CommentPageData` / 收藏夹 / 分页响应 |
| `ComicAlbum.ets` | 漫画实体 `ComicAlbum`、章节 `ComicChapter`、评论 `CommentInfo`，以及 DTO → 实体的纯转换函数 |
| `AlbumFeed.ets` | 列表顺序 `Feed` / `FeedSection`，只存 id 序与标题，不存漫画内容 |
| `Album.ets` | 运行时模型：`DownloadTask`（排队 / 下载中 / 暂停 / 完成 / 错误）、`UserSession`、`AlbumViewModel`（列表卡片展示字段） |

---

## 核心模块深度解析

### 1. 加密体系（`CryptoUtils.ets`）

JMComic 移动端 API 要求请求携带 Token 签名，响应体经过 AES 加密：

```typescript
// token = MD5(ts + secret)；tokenparam = "ts,ver"
token = MD5(ts + APP_TOKEN_SECRET)         // 常规接口
token = MD5(ts + APP_TOKEN_SECRET_2)       // /chapter_view_template 专用

// 响应解密：AES-256-ECB
// key = MD5(ts + secret)，32 字节，PKCS7 padding
```

| 密钥 | 值 |
|------|-----|
| APP_TOKEN_SECRET | 18comicAPP |
| APP_TOKEN_SECRET_2 | 18comicAPPContent |
| APP_DATA_SECRET | 185Hcomic3PAPP7R |
| APP_VERSION | 2.0.20 |

### 2. 域名故障转移（`DomainManager.ets`）

```
1. 失败计数：每个域名跟踪失败次数，优先选择失败次数最少的域名
2. 并行探活：初始化时并行探测所有域名可达性，标记不可达域名
3. 定期复探：后台每 5 分钟重新探测不可达域名，恢复后自动加入可用池
4. 全死降级：所有域名不可达时重置计数，回退到未探活状态
5. 手动线路：Index 页「线路」菜单可手动指定 API / 图片 CDN
```

### 3. scramble 图片解码（`ImageDecodeUtils.ets` + TaskPool）

章节图片可能被水平分割成多条带，需按算法还原：

```typescript
// 分割数计算：依据 scrambleId / photoId 阈值与文件名 MD5 决定
getSegmentationNum(scrambleId, photoId, filename)
  → photoId < scrambleId        → 0（无需解密）
  → photoId < 268850            → 10
  → MD5(photoId + filename) 末位字符哈希决定 8~10 的分割数

// 还原：readPixelsToBuffer + writeBufferToPixelMap 重排条带
decodeImage(pixelMap, num) → 还原后的 PixelMap
```

解码任务通过 **TaskPool**（`@Concurrent` 独立函数）并行执行，避免阻塞 UI 线程。

### 4. 图片阅读器（`ImageViewerPage.ets`）

针对大图集（数百张）的阅读体验做了深度优化：

```
竖向模式：Scroll (ScrollDirection.FREE + 缩放 0.5x~3.0x)
  └── List (LazyForEach + cachedCount(10))     ← 懒加载 + 屏外缓存项减少白屏
横向模式：Swiper (LazyForEach + cachedCount(2)) ← 左→右 / 右→左，进入即定位上次页码
```

- **预加载**：`onAppear` 触发 `preloadNearbyPixelMaps(centerIndex)`，预加载当前项 ±10 范围
- **磁盘缓存**：解码结果 PNG 落 ComicLibrary（`filesDir/JMComic/albums/{albumId}/chapters/{章节}_{photoId}/`），滑出视口释放内存、滑回读盘秒加载
- **进度追踪**：`onVisibleAreaChange([0.5])` 记录当前页；页码 / 最后章节 / 已读标记写入 RDB（`read_state`）
- **滑杆跳页**：底栏滑杆直接定位任意页，页码与模式按钮双向同步
- **节流刷新**：每解码 5 张才刷新一次 UI，降低负载
- **章节切换**：复位滚动 + 重置缩放

### 5. 本地数据与缓存（`storage/` + `CacheManager.ets` + `ComicLibrary.ets`）

| 数据 | 存储 | 内容 | 过期 / 清理 |
|------|------|------|-------------|
| 漫画实体 | RDB `album` / `chapter` | 标题、作者、标签、章节目录 | 随刷新更新 |
| 列表顺序 | RDB `feed` / `feed_section` / `feed_item` | id 序与分区标题 | 超过刷新间隔联网更新 |
| 分页快照 | RDB `page_cache` | 分类 / 搜索 / 收藏分页响应 | 页面始终联网，快照只作首屏占位 |
| 阅读进度 | RDB `read_state` | 页码、最后章节、已读标记 | 永久，可在设置清除页码（保留已读）/ 已读记录（页码、已读、最后章节全清） |
| 账号与偏好 | RDB `account` / `pref` | 多账号、自动登录、主题等 | 永久 |
| 章节图片 | 文件仓库 ComicLibrary | 解码 PNG + `meta.json` | 阅读缓存 / 已导出内容按天整本清理，阅读记录保留 |
| 原始图 | `cacheDir/JMComic/originals` | 服务器原图（解码原料） | 清理缓存即删，缺了下次重下 |

页面读取一律「本地优先」：本地有数据先渲染，超过刷新间隔才联网；网络响应只写表，页面写完再读一次。重新加载（切分类 / 换关键词 / 切收藏夹 / 过期重拉）时不清空屏上内容、不整页进加载态，等数据落库后整体替换；只有首次启动、页面上没有任何本地数据时才显示加载态。

### 6. 下载与导出体系（`DownloadService.ets` + `ComicLibrary.ets` + `ZipExporter.ets`）

- `DownloadService`：章节级任务队列，单引擎单并发顺序下载，支持暂停 / 继续 / 删除；任务持久化，重启后非终态恢复为「已暂停」，已下载图片按序号断点续传
- 图片管线：优先复用阅读器已解码的 PNG → 缺失才下载原图 → scramble 解码 → 重编码 PNG 落盘 → 写 `meta.json`
- 落盘统一由 ComicLibrary 负责，下载器只维护任务清单与「已下载」标记
- 通知栏：`DownloadNotifier` 按最小间隔节流发布进度，专辑完成时提醒
- 导出：`ZipExporter` 用 `zlib.compressFile` 打包专辑目录（保留「章节 / 序号」层级），经 `DocumentViewPicker.save` 由用户选择位置，临时包放 `cacheDir/zip_export` 并在导出后清理

---

## 数据流

### 数据请求链路

```text
用户操作 → UI (Page / NavDestination)
           ↓ 先读本地
          DAO / CacheManager（RDB）
           ├── 数据新鲜 → 直接渲染
           └── 过期 / 缺失 → ApiService
                              ├── CryptoUtils 生成 Token 签名头
                              ├── DomainManager 选择最佳 API 域名
                              └── HttpClient 发起请求（携带 Cookie）
                                   ↓ 响应
                              CryptoUtils AES 解密 data
                                   ↓
                              写表（AlbumDao / FeedDao / PageCacheDao）
           ↓
          UI 重新读表渲染 (@State / ForEach)
```

### 图片解码链路

```text
ImageViewerPage 滚动到可视区
    ↓ onAppear / 预加载
ComicLibrary.ensureImage(ctx, index)
    ├── 仓库已有 PNG → 直接读
    └── 缺失 → 下载原图（cacheDir/JMComic/originals）
              ↓ TaskPool @Concurrent 并行解码
           scramble 还原 → 重编码 PNG → 原子写入章节目录
    ↓ 整章对齐完成
ComicLibrary.commitChapter → 写 meta.json（提交标记）
    ↓ 滑入视口
从磁盘 PNG 创建 PixelMap → Image 显示
    ↓ 滑出视口
释放 PixelMap（内存回收），磁盘文件兜底
```

### 关键设计

- **域名故障转移**：请求失败自动切换域名重试，后台定期复探恢复，保证线路可用性
- **Cookie 会话**：HttpClient 全局管理 Cookie，重要 Cookie（AVS、ipcountry 等）优先，模拟 Session
- **图片三级缓存**：内存 PixelMap → 仓库 PNG → 网络下载，滚动阅读不闪烁
- **单份图片**：阅读、下载、导出共用 ComicLibrary 里的同一份 PNG，不重复占空间
- **原子替换**：先写 `.tmp` 再改名，换版时逐页替换，任何时刻读到都是完整文件
- **本地优先**：页面先读 RDB 渲染，超时才联网；写库与读库分离，避免 UI 持有网络对象
- **阅读进度**：存 RDB，返回详情页时刷新「看过」状态；设置页可一键清除页码
- **去重机制**：分页数据按 ID 去重合并，列表顺序单独存 `feed_item`，避免 ForEach key 冲突

---

## 权限说明

```json
ohos.permission.INTERNET   网络访问（请求 API 与图片 CDN）
```

---

## 构建配置

```
SDK 版本:    target 26.0.0 | compatible 6.1.1(24)
编译工具:    Hvigor + BiSheng 编译器
模块:        entry（HAP）+ common（HAR）
设备类型:    phone, tablet, 2in1, car, wearable, tv
权限:        ohos.permission.INTERNET
混淆:        release 模式启用（obfuscation-rules.txt）
深色主题:    resources/dark 已配置
```

---

## 安装调试

**小白调试助手（推荐）**

下载链接：[Auto-Installer](https://github.com/likuai2010/auto-installer/releases/latest)

- [下载教程文档](https://github.com/Zitann/HarmonyOS-Haps/raw/refs/heads/main/assets/guide.pdf)
- [视频教程](https://www.bilibili.com/video/BV1hkZ7YnEMd/)

**手动构建**

```bash
# DevEco Studio 中打开项目根目录
# 配置 signingConfigs（debug / release）
# 选择设备类型（phone / tablet / 2in1）
# Build → Build HAP(s)
```

**命令行构建**

```bash
# 构建 debug HAP
hvigorw assembleHap --mode module -p product=default --no-daemon
# 产物路径: entry/build/default/outputs/default/entry-default-signed.hap
```

**安装到设备**

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

---

## 开发指引

### ArkTS 语法约束

本项目遵循 ArkTS 严格语法限制，关键注意点：

- 不支持 `any` / `unknown` 类型，需显式声明
- 不支持解构赋值、`for..in` 遍历对象
- 不支持 `Function.apply/call/bind`、`Symbol`（除 `Symbol.iterator`）
- 不支持 `as const` 断言、条件类型别名、索引签名
- TaskPool 函数必须是 `@Concurrent` 独立函数，参数与返回值需显式类型标注
- `@Builder` 方法不支持链式事件绑定（如 `.onClick()`）

详见项目配置中的 `user_rules` 与 [ArkTS 语法规则](./code-linter.json5)。

### 新增页面步骤

1. 在 `entry/src/main/ets/pages/` 下创建 `.ets` 文件，实现 `NavDestination` 并导出 `@Builder` 构建函数（`Index` 是唯一 `@Entry`，`main_pages.json` 只登记它）
2. 在 `entry/src/main/resources/base/profile/router_map.json` 中注册 `name` / `pageSourceFile` / `buildFunction`
3. 跳转统一用 `common/NavHelper` 的 `navPush` / `navReplace` / `navPop`，路由参数接口写在 `common/RouteParams.ets`
4. 取参放在 `onReady`（`aboutToAppear` 时路由参数尚未就绪）；网络数据走 `ApiService`，先落库再读表渲染

### 新增第三方库

1. 在对应模块的 `oh-package.json5` 中添加依赖
2. 确认 `oh-package-lock.json5` 版本解析
3. 使用官方 `@kit.*` 模块优先，避免非必要依赖

---

## 反馈

如果您在使用过程中遇到问题，或有改进建议，欢迎提交 Issue 或 PR。

- Telegram 交流群：https://t.me/HMTGchannel 、 https://t.me/HMTGchat
- QQ 群：1075753335

---

## 许可证

本项目基于 [GNU General Public License v3.0](./LICENSE.md) 开源。

```
JMComic-HarmonyOS
Copyright (C) 2024-2026 JMComic-HarmonyOS contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
```
