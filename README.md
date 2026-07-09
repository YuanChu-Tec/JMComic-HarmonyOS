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

JMComic-HarmonyOS 是基于 **ArkTS / ArkUI** 构建的 **HarmonyOS 漫画客户端**，包名 `com.yuanchu.jmcomic`，目标设备覆盖手机、平板、2in1、车机、穿戴、TV。项目从 JMComic 的 Python / Java / QT 生态移植而来，完整复刻了核心数据链路（API 加解密、图片 scramble 解码、域名故障转移等）。

| 属性 | 值 |
|------|-----|
| 包名 | com.yuanchu.jmcomic |
| 版本 | 1.0.8 (versionCode: 1000008) |
| 最低兼容 SDK | 6.1.0(23) |
| 目标 SDK | 6.1.1(24) |
| 应用类型 | Stage 模型 + ArkTS |
| 许可证 | GPL-3.0 |

核心技术选型：

- **UI 框架** — ArkUI 声明式 UI（`@Component` / `@State` / `@StorageProp`），HdsTabs 悬浮页签
- **网络层** — `@kit.NetworkKit` http，封装 Cookie 会话管理与失败重试
- **域名管理** — 多 API / 图片 CDN 域名故障转移，失败计数 + 并行探活 + 定期复探
- **加密体系** — MD5 Token 签名 + AES-256-ECB 响应数据解密（`@kit.CryptoArchitectureKit`）
- **图片解码** — scramble 分割还原算法（TaskPool 并行），磁盘 PNG 缓存 + 视口预加载
- **持久化** — Preferences 键值存储（列表缓存、搜索历史、阅读进度、下载任务）
- **分享与通知** — 系统分享（ShareKit）+ 通知栏下载进度（NotificationKit）

---

## 功能特性

- **首页**：最新上传 + 推荐分区横向滑动
- **分类浏览**：同人 / 单本 / 短篇 / 韩漫 / 美漫 / Cosplay / 3D / 英文站，支持多种排序（最新、最多观看、最多图片、月/周/日排行）
- **搜索**：关键词搜索 + 无上限搜索历史
- **漫画详情**：作者、标签、系列（章节）列表、相关作品，收藏夹管理
- **图片阅读器**：
  - 整本竖排拼接滚动，支持双指缩放（0.5x ~ 3.0x）
  - scramble 加密图片自动解码还原
  - 视口 ±10 项预加载 + 磁盘 PNG 缓存，滑动不白屏
  - 章节阅读进度自动记录，返回列表显示「看过」标记
- **收藏与历史**：收藏夹分组、观看历史自动同步
- **登录**：账号密码登录，凭据自动保存与自动登录
- **下载管理**：章节下载队列（暂停 / 继续 / 删除），通知栏展示下载进度
- **讨论区**：评论浏览、多模式筛选、登录后回复
- **分享**：系统分享面板分享漫画详情
- **清理缓存**：一键清空 filesDir 与 cacheDir

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
│   │   ├── pages/                         # 页面层（8 个路由页面）
│   │   │   ├── Index.ets                  # 主入口（首页 / 分类 / 讨论区 / 个人中心）
│   │   │   ├── SearchPage.ets             # 搜索页
│   │   │   ├── AlbumDetailPage.ets        # 漫画详情页（分享 / 下载 / 通知）
│   │   │   ├── ImageViewerPage.ets        # 图片阅读器
│   │   │   ├── LoginPage.ets              # 登录页
│   │   │   ├── DownloadPage.ets           # 下载管理页
│   │   │   ├── AlbumCommentPage.ets       # 评论区
│   │   │   └── AboutPage.ets              # 关于 / 防失联
│   │   ├── models/
│   │   │   └── Album.ets                  # 数据模型（专辑 / 章节 / 图片 / 任务）
│   │   ├── network/
│   │   │   ├── ApiService.ets             # API 服务层（单例，全部接口封装）
│   │   │   ├── DomainManager.ets          # 域名故障转移
│   │   │   ├── HttpClient.ets             # HTTP 客户端（Cookie / 重试）
│   │   │   └── DownloadService.ets        # 下载任务队列
│   │   └── common/
│   │       ├── Constants.ets              # 全局常量（域名 / 分类 / 密钥 / 端点）
│   │       ├── CryptoUtils.ets            # Token 签名 + AES 解密
│   │       ├── ImageDecodeUtils.ets       # scramble 图片解码
│   │       ├── DecodedImageCache.ets      # 已解码图片磁盘缓存
│   │       ├── DownloadManager.ets        # 整本下载 + 通知栏进度
│   │       ├── CacheManager.ets           # Preferences 缓存管理
│   │       ├── CommentItem.ets            # 评论项组件
│   │       └── MenuPopup.ets              # 菜单 / 路由弹窗
│   └── src/main/resources/                # 资源（颜色 / 字符串 / 图片 / 深色主题）
└── hvigor/                                # Hvigor 构建配置
```

### 分层架构

```text
┌─────────────────────────────────────────────┐
│              UI Layer (Pages)                │
│   Index, SearchPage, AlbumDetailPage, ...   │
├─────────────────────────────────────────────┤
│            Service Layer                     │
│   ApiService / DownloadService / Manager    │
├─────────────────────────────────────────────┤
│          Infrastructure Layer                │
│   HttpClient / DomainManager / CacheManager │
├─────────────────────────────────────────────┤
│             Utils Layer                      │
│   CryptoUtils / ImageDecodeUtils / ...      │
├─────────────────────────────────────────────┤
│        HarmonyOS Kit（ArkUI / Network / ...）│
└─────────────────────────────────────────────┘
```

---

## 技术栈

### 鸿蒙 Kit 套件

| Kit | 用途 |
|-----|------|
| `@kit.AbilityKit` | UIAbility 生命周期、getContext、wantAgent（通知点击跳转） |
| `@kit.ArkUI` | 声明式 UI 框架（@Component, @State, @StorageProp, Tabs, Scroll） |
| `@kit.ArkTS` | 语言运行时、util（MD5 hex 转换）、taskpool（并行解码） |
| `@kit.NetworkKit` | HTTP 请求（@ohos.net.http） |
| `@kit.ArkData` | Preferences 持久化、uniformTypeDescriptor（分享类型） |
| `@kit.CoreFileKit` | 文件 I/O（fileIo）、DocumentViewPicker（文件选择） |
| `@kit.ImageKit` | 图片解码（PixelMap / ImageSource / ImagePacker） |
| `@kit.CryptoArchitectureKit` | MD5、AES-256-ECB（Token 与响应解密） |
| `@kit.BasicServicesKit` | 剪贴板（pasteboard）、设备信息（deviceInfo）、BusinessError |
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

### pages/ — 页面层（8 个路由页面）

| 文件 | 功能 |
|------|------|
| `Index.ets` | 主入口页：HdsTabs 悬浮页签承载首页 / 分类 / 讨论区 / 个人中心；沉浸式顶部栏；线路切换 |
| `SearchPage.ets` | 关键词搜索、搜索历史（Flex 自动换行展示） |
| `AlbumDetailPage.ets` | 漫画详情：作者 / 标签 / 章节列表 / 收藏 / 分享 / 阅读进度 |
| `ImageViewerPage.ets` | 图片阅读器：整本拼接滚动、缩放、scramble 解码、预加载、进度追踪 |
| `LoginPage.ets` | 账号密码登录 |
| `DownloadPage.ets` | 下载任务管理（暂停 / 继续 / 删除） |
| `AlbumCommentPage.ets` | 评论区 |
| `AboutPage.ets` | 关于页（防失联入口） |

### network/ — 网络层

| 文件 | 职责 |
|------|------|
| `HttpClient.ets` | HTTP 封装：全局 Cookie 管理（重要 Cookie 优先）、自动解析 Set-Cookie、失败重试、二进制下载 |
| `DomainManager.ets` | 域名故障转移：失败计数、并行探活、定期复探（5 分钟）、全死降级、手动指定线路 |
| `ApiService.ets` | 单例 API 服务：Token 签名头、响应 AES 解密、全部业务接口（搜索 / 详情 / 章节 / 收藏 / 登录 / 评论 / 观看历史） |
| `DownloadService.ets` | 下载任务队列：并发控制、暂停 / 继续 / 删除、任务持久化恢复 |

### common/ — 工具与组件层

| 文件 | 职责 |
|------|------|
| `Constants.ets` | 域名列表、图片 URL 模板、APP 密钥、分类 / 排序映射、HTTP Headers |
| `CryptoUtils.ets` | MD5 Token 计算、AES-256-ECB 响应解密（对应 Python JmCryptoTool） |
| `ImageDecodeUtils.ets` | scramble 分割数计算与图片还原解码（对应 Python JmImageTool） |
| `DecodedImageCache.ets` | 已解码图片磁盘 PNG 缓存（cacheDir/decoded/{photoId}/{index}.png） |
| `DownloadManager.ets` | 整本漫画下载：多章节顺序下载、取消、通知栏进度发布 |
| `CacheManager.ets` | Preferences 缓存：分类列表（TTL 30 分钟）、搜索历史、阅读进度、下载任务 |
| `CommentItem.ets` | 评论项组件 |
| `MenuPopup.ets` | 菜单 / 路由（线路）选择弹窗 |

### models/ — 数据模型

`Album.ets` 定义了全部接口数据模型与 JSON 序列化结构：

| 模型 | 说明 |
|------|------|
| `JmAlbumInfo` / `JmAlbumDetail` | 漫画列表项 / 完整详情（章节、标签、作者） |
| `JmPhotoInfo` / `JmImageInfo` | 章节信息 / 单张图片（含 download_url） |
| `PictureData` / `JmPictureResp` | 章节图片响应（含 scramble_id） |
| `DownloadTask` | 下载任务（状态机：排队 / 下载中 / 暂停 / 完成 / 错误） |
| `UserSession` / `JmUserData` | 登录会话 |
| `CommentInfo` / `CommentPageData` | 评论数据 |
| `FavoriteAlbumItem` / `FavoriteFolderItem` | 收藏夹数据 |

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
Scroll (ScrollDirection.FREE + 缩放)      ← 整本缩放（0.5x~3.0x）
  └── List (LazyForEach + cachedCount(10))  ← 懒加载 + 缓存项减少白屏
        └── ListItem → Image
```

- **预加载**：`onAppear` 触发 `preloadNearbyPixelMaps(centerIndex)`，预加载当前项 ±10 范围
- **磁盘缓存**：解码结果写 PNG 到 `cacheDir/decoded/{photoId}/{index}.png`，滑出视口释放内存、滑回秒加载
- **进度追踪**：`onVisibleAreaChange([0.5])` 记录当前页；章节阅读进度写入 Preferences
- **节流刷新**：每解码 5 张才刷新一次 UI，降低负载
- **章节切换**：`scrollEdge(Edge.Top)` 复位滚动 + 重置缩放

### 5. 缓存体系（`CacheManager.ets` + `DecodedImageCache.ets`）

| 缓存 | 存储 | 内容 | 过期策略 |
|------|------|------|----------|
| 分类列表 | Preferences | category+order 分 key 缓存 | TTL 30 分钟 |
| 搜索结果 | Preferences | 关键词缓存 | TTL 30 分钟 |
| 收藏列表 | Preferences | folderId 分 key 缓存 | TTL 10 分钟 |
| 搜索历史 | Preferences | 关键词（无数量限制） | 永久 |
| 阅读进度 | Preferences | albumId-chapterId 键 | 永久 |
| 下载任务 | Preferences | 任务队列序列化 | 永久 |
| 解码图片 | 磁盘 cacheDir/decoded | 解码后 PNG | 随缓存清理 |

### 6. 下载体系（`DownloadService.ets` + `DownloadManager.ets`）

- `DownloadService`：任务队列，单并发顺序下载，支持暂停 / 继续 / 删除，任务持久化恢复（非终态恢复为暂停）
- `DownloadManager`：整本漫画下载，两遍流程（先统计总图片数 → 再逐章逐图下载），支持取消（HTTP `destroy()`）
- 通知栏：`downloadTemplate` 展示当前图片数 / 总数与百分比

---

## 数据流

### 数据请求链路

```text
用户操作 → UI (Page)
           ↓ 业务调用
          ApiService
           ├── CryptoUtils 生成 Token 签名头
           ├── DomainManager 选择最佳 API 域名
           └── HttpClient 发起请求（携带 Cookie）
                ↓ 响应
           CryptoUtils AES 解密 data
           ↓
          UI 渲染 (@State / ForEach)
```

### 图片解码链路

```text
ImageViewerPage 滚动到可视区
    ↓ onAppear / 预加载
getChapterPictures(photoId, scrambleId)
    ↓
ImageDecodeUtils 计算分割数 + 下载原图
    ↓ TaskPool @Concurrent 并行解码
DecodedImageCache.saveDecodedImage (写 PNG)
    ↓ 滑入视口
从磁盘 PNG 创建 PixelMap → Image 显示
    ↓ 滑出视口
释放 PixelMap（内存回收），磁盘缓存兜底
```

### 关键设计

- **域名故障转移**：请求失败自动切换域名重试，后台定期复探恢复，保证线路可用性
- **Cookie 会话**：HttpClient 全局管理 Cookie，重要 Cookie（AVS、ipcountry 等）优先，模拟 Session
- **图片三级缓存**：内存 PixelMap → 磁盘 PNG → 网络下载，滚动阅读不闪烁
- **阅读进度**：仅本地保存（Preferences），返回详情页时刷新「看过」状态
- **去重机制**：分页数据使用 Map 按 ID 去重合并，避免 ForEach key 冲突

---

## 权限说明

```json
ohos.permission.INTERNET   网络访问（请求 API 与图片 CDN）
```

---

## 构建配置

```
SDK 版本:    target 6.1.1(24) | compatible 6.1.0(23)
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

1. 在 `entry/src/main/ets/pages/` 下创建 `.ets` 文件，添加 `@Entry` 装饰器
2. 在 `entry/src/main/resources/base/profile/main_pages.json` 中注册路由
3. 通过 `router.pushUrl({ url: 'pages/XXX' })` 跳转
4. 如需网络数据，调用 `ApiService.getInstance()` 对应方法

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
