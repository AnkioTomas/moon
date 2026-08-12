# Book 插件开发指南

> 面向贡献者的架构参考与编码规范。阅读前请确保已通读 [README.md](README.md)。

---

## 目录

- [项目概览](#项目概览)
- [目录结构](#目录结构)
- [架构总览](#架构总览)
- [模块职责](#模块职责)
- [数据流](#数据流)
- [UI 框架](#ui-框架)
- [配置系统](#配置系统)
- [编码规范](#编码规范)
- [构建与发布](#构建与发布)
- [开发环境搭建](#开发环境搭建)
- [调试](#调试)
- [提交规范](#提交规范)

---

## 项目概览

Book 是一个运行在 [KOReader](https://koreader.rocks/) Lua 环境中的插件（`.koplugin`），为墨水屏阅读器提供连接远端 Book 服务的全屏书库桌面。

**核心约束**：

- 运行环境是 KOReader 内嵌的 LuaJIT + 自带库，**没有 npm/pip/gradle**
- 目标设备是墨水屏（Kindle、Kobo、PocketBook 等），**内存有限、刷新昂贵**
- 所有 UI 必须通过 KOReader Widget 体系构建（不是 HTML/CSS）
- 插件不依赖任何外部 Lua 库，只用 KOReader 已有的模块

---

## 目录结构

```text
moon/                           # 仓库根目录
├── book.koplugin/              # 插件目录（部署时整个复制到 KOReader plugins/）
│   ├── _meta.lua               # 插件元数据（name, fullname, description）
│   ├── main.lua                # 入口：BookPlugin 类、生命周期、事件钩子
│   ├── bookversion.lua         # 版本号（CI 注入，开发时显示 0.0.0-dev）
│   │
│   ├── desktop.lua             # 桌面壳：四栏底栏 + Tab 切换 + 内容区调度
│   ├── home.lua                # 主页 Tab：时钟/一言、统计卡片、最近阅读、在读网格
│   ├── library.lua             # 图书馆 Tab：搜索/筛选/分页、封面网格
│   ├── insight.lua             # 统计 Tab：KPI 大字、日历热力图、当日书单
│   ├── detail.lua              # 书籍详情浮层：封面 + 元信息 + 阅读按钮
│   ├── readermenu.lua          # 阅读页悬浮面板：排版调节、目录、首页
│   │
│   ├── api.lua                 # HTTP API 客户端（socket.http + Bearer Token）
│   ├── cover.lua               # 封面下载/缓存/异步队列/缩略图解码
│   ├── bookui.lua              # UI 工具：缩放系数、色阶常量、网格度量、进度条
│   ├── stats_db.lua            # 读取 KOReader statistics.sqlite3
│   ├── stats_sync.lua          # 阅读统计后台上报（注册设备 + import）
│   │
│   ├── moon/                   # 子模块命名空间
│   │   ├── settings.lua        # 配置持久化（$DATA/.moon/settings/config.lua）
│   │   └── ui/
│   │       └── settings.lua    # 设置 Tab UI 渲染
│   │
│   ├── icons/                  # SVG 图标（底栏、设置、阅读面板等）
│   ├── http/                   # 保留目录（当前为空）
│   ├── ui/components/          # 保留目录（当前为空）
│   └── source/                 # 保留目录（webdav/、wechat/ 均为空）
│
├── koreader/                   # Git submodule → koreader/koreader（IDE 补全 + 本机模拟器）
├── screenshots/                # README 截图
├── .github/workflows/
│   └── release.yml             # CI：打 tag → 注入版本 → zip → GitHub Release
├── README.md
├── DEVELOPMENT.md              # 本文件：架构与开发环境
├── LICENSE                     # MIT
└── .gitmodules
```

**关键规则**：

- `source/`、`http/`、`ui/components/` 是预留目录，当前为空
- `koreader/` 子模块用于 IDE 补全，以及在本机编译/运行模拟器；**不会打包进插件**
- 部署产物是 `book.koplugin/` 目录本身

---

## 架构总览

```text
┌──────────────────────────────────────────────────────────┐
│  KOReader 宿主                                           │
│  ├─ FileManager（文件管理器实例）                          │
│  │   └─ BookPlugin (main.lua)  ← WidgetContainer 子类    │
│  └─ ReaderUI（阅读器实例）                                │
│      └─ BookPlugin (main.lua)  ← 同一个类，不同实例       │
└──────────────────────────────────────────────────────────┘
         │
         │ openDesktop()
         ▼
┌──────────────────────────────────────────────────────────┐
│  Desktop (desktop.lua)  ← InputContainer，全屏覆盖       │
│  ├─ 底栏：图书馆 / 主页 / 统计 / 设置                     │
│  ├─ 内容区由 tab 决定：                                   │
│  │   ├─ "home"     → Home.build(ctx)                     │
│  │   ├─ "library"  → Library.build(ctx)                  │
│  │   ├─ "stats"    → Insight.build(ctx)                  │
│  │   └─ "settings" → Settings.build(desktop)             │
│  └─ 浮层：Detail (detail.lua)                            │
└──────────────────────────────────────────────────────────┘
         │
         │ 阅读页中部点击
         ▼
┌──────────────────────────────────────────────────────────┐
│  ReaderFloatMenu (readermenu.lua) ← InputContainer       │
│  底部半屏面板：排版调节 / 目录 / 更多 / 首页              │
└──────────────────────────────────────────────────────────┘
```

**实例生命周期**：

1. KOReader 启动 → PluginLoader 加载 `book.koplugin/` → 创建 `BookPlugin` 实例
2. BookPlugin 存在两种上下文：FM（文件管理器）实例和 Reader（阅读器）实例
3. `openDesktop()` 创建 `Desktop` 全屏 widget 并 `UIManager:show()`
4. 关闭桌面时 `UIManager:close()` 回到 FM
5. 阅读器中，BookPlugin 通过 `registerTouchZones` 注册中部点击热区，触发悬浮面板

---

## 模块职责

### main.lua — 插件核心

| 职责 | 说明 |
|------|------|
| 生命周期 | `init()` → 注册菜单、Dispatcher、patch FM |
| 事件钩子 | `onReaderReady`、`onCloseDocument`、`onSuspend`、`onSetDimensions` |
| 桌面管理 | `openDesktop(filter)` → 创建/关闭 Desktop |
| 书籍操作 | `openBook(book)` → 下载 + 打开阅读器 |
| 进度同步 | `pushCurrentProgress()`、`pullCurrentProgress()` |
| 统计上报 | `pushReadingStats()` → 委托 `StatsSync` |
| 本地缓存 | `localPathFor()`、`touchLocalBook()`、`cleanupStaleLocalBooks()`、`clearLocalCache()` |
| 元数据缓存 | `rememberBookMeta()`、`getCachedBookMeta()` |
| 文件映射 | `fileMap`（本地路径 ↔ 远端 filename + 最后打开时间） |

### api.lua — HTTP 客户端

纯函数式 API 封装，无状态（除 recent/insight 内存缓存）。

```lua
local api = Api:new{ base_url = "https://...", token = "bk_..." }
local data, err = api:listBooks{ page = 1, search = "三体" }
```

**设计要点**：

- 统一走 `_request()` 方法，自动处理 JSON 解析、BOM 去除、401、超时
- 二进制下载（书籍/封面）通过 `sink_file` 参数区分，`Connection: close` 防挂死
- `as_json` 参数控制 POST body 格式（form vs JSON）
- 内存缓存有 TTL（recent 5 分钟，insight 30 分钟），可手动清除

### desktop.lua — 桌面壳

- 继承 `InputContainer`，`covers_fullscreen = true`
- 管理四个 Tab 的构建和切换
- 通过 `ctx()` 方法向各 Tab 传递上下文（width, height, plugin, api, desktop, filter）
- 底栏手势判定：按 x 坐标计算点中哪个 Tab
- 左右滑动翻页（图书馆），下滑关闭

### home.lua / library.lua / insight.lua — 页面模块

**统一模式**：模块导出 `Module.build(ctx)` 函数，返回一个 widget 树。

- **Home**：时钟/一言 + 统计卡片（已读/未读可点击跳转图书馆）+ 最近阅读封面 + 在读网格
- **Library**：顶栏（搜索/筛选/清除/总数）+ 封面网格 + 分页。筛选互斥：同时只有一个条件
- **Insight**：从 `/index/stats/insight` 拉数据，渲染 KPI 大字 + 月度日历热力图 + 当日书单

### cover.lua — 封面管理

- `cachedPath()` → 查找本地缓存（按后缀探测 jpg/png/webp/gif）
- `ensure()` → 同步下载并嗅探格式
- `ensureAsync()` → 异步队列（`pump` 串行执行，避免并发 HTTP）
- `widget()` → 解码缩略图（`RenderImage:renderImageFile`），**禁止原图进内存**
- `placeholder()` → 无封面时的文字占位框

### bookui.lua — UI 工具

提供所有 UI 模块共用的度量和色阶：

| 函数 | 用途 |
|------|------|
| `UI.sz(n)` | 逻辑像素 → 物理像素，考虑 DPI + `ui_scale` |
| `UI.fontSize(n)` | 字号缩放 |
| `UI.face(name, size)` | 获取缩放后的 Font Face |
| `UI.iconSz()` | 图标统一边长 |
| `UI.barH()` | 底栏高度 |
| `UI.ink()` / `muted()` / `dim()` / `rule()` / `track()` | 墨水屏色阶 |
| `UI.coverGridMetrics(w, h)` | 计算网格列宽/封面尺寸/列数 |
| `UI.progressBar(w, h, pct)` | 简易进度条 widget |

### readermenu.lua — 阅读页悬浮面板

- 底部半屏面板，覆盖在阅读页之上
- 排版调节项：字体、字号、行距、字重、对比度、边距、分页/滚动
- 操作按钮：目录、更多设置、首页（关书回桌面）、关闭
- 读取/修改 KOReader CRe 引擎参数（通过 `document.configurable` 和 `Event`）

### stats_db.lua + stats_sync.lua — 统计上报

- `StatsDb` 读取 KOReader 的 `statistics.sqlite3`，解析书籍和 page_stat
- 通过 filemap / metamap / MD5 映射将本地路径解析为远端 filename
- `StatsSync.pushAsync()` 在 UIManager 后台分步执行：注册设备 → 读书籍 → 读 page_stat → 上传

---

## 数据流

### 书籍列表

```text
用户切到图书馆 Tab
  → Desktop:switchTab("library")
  → Desktop:buildLibrary()
  → Library.build(ctx)
  → ctx.api:listBooks(opts)        ← HTTP GET /index/book/list
  → 返回 JSON { data: { records: [...], total: N } }
  → Library 渲染封面网格
  → Cover.ensureAsync() 异步下载缺失封面
  → 下载完成 → Cover idle handler → 刷新当前页
```

### 打开书籍

```text
用户点封面 → Desktop 打开 Detail 浮层
  → 用户点"开始阅读"
  → BookPlugin:openBook(book)
  → 本地有文件？直接打开 : 下载（显示进度条）
  → 记录 fileMap + metaMap
  → 关闭桌面 → ReaderUI:showReader(path)
```

### 进度同步

```text
onReaderReady    → pullCurrentProgress()  ← GET /index/book/progress
onCloseDocument  → pushCurrentProgress()  → POST /index/book/progressUpdate
onSuspend        → pushCurrentProgress()
```

### 配置持久化

```text
MoonSettings.get()
  → 首次调用：打开 $DATA/.moon/settings/config.lua (LuaSettings)
  → 如果空：从 G_reader_settings 旧键迁移 → 写入新文件 → 删旧键
  → 返回 data 表的引用

MoonSettings.save(s)
  → 写入磁盘
```

---

## UI 框架

### KOReader Widget 体系

插件使用 KOReader 内置的 widget 系统，核心类：

| Widget | 用途 |
|--------|------|
| `WidgetContainer` | 插件基类（main.lua） |
| `InputContainer` | 可接收手势的容器（Desktop、Detail、ReaderFloatMenu） |
| `FrameContainer` | 带边框/背景/内边距的容器 |
| `CenterContainer` | 子元素居中 |
| `LeftContainer` / `RightContainer` | 子元素靠左/靠右 |
| `VerticalGroup` / `HorizontalGroup` | 垂直/水平布局 |
| `VerticalSpan` / `HorizontalSpan` | 间距占位 |
| `OverlapGroup` | 层叠布局（用于底栏覆盖在内容区上方） |
| `TextWidget` / `TextBoxWidget` | 单行/多行文本 |
| `ImageWidget` | 图片（支持 SVG、位图） |
| `LineWidget` | 分割线 |
| `ScrollableContainer` | 可滚动容器（pcall 加载，旧版 KOReader 可能不存在） |
| `Button` / `ButtonTable` | 按钮 |
| `TitleBar` | 标题栏 |
| `Menu` | 菜单列表 |
| `ProgressWidget` | 进度条 |
| `InfoMessage` / `ConfirmBox` | 弹窗 |

### 手势处理

```lua
-- 在 init() 中定义 ges_events
self.ges_events = {
    TapBar = {
        GestureRange:new{
            ges = "tap",
            range = function() return Geom:new{...} end,
        },
    },
}

-- 对应的处理函数（前缀 on）
function Desktop:onTapBar(_, ges)
    -- ges.pos.x, ges.pos.y
end
```

### 屏幕刷新

```lua
UIManager:show(widget)                    -- 显示 widget
UIManager:close(widget)                   -- 关闭 widget
UIManager:setDirty(widget, "full")        -- 全刷（墨水屏）
UIManager:setDirty(widget, "ui")          -- 局部刷
UIManager:setDirty(widget, "ui", rect)    -- 指定区域刷
UIManager:scheduleIn(seconds, callback)   -- 延时调度
UIManager:nextTick(callback)              -- 下一帧执行
```

### 墨水屏适配要点

1. **避免频繁刷新**：封面异步下载完成后合并刷新（`Cover.setIdleHandler` + 0.8s 去抖）
2. **禁止大图进内存**：封面必须用 `RenderImage:renderImageFile(path, false, w, h)` 按目标尺寸解码
3. **色阶有限**：只用黑、深灰 (0x33)、灰 (0x44)、中灰 (0x55)、浅灰 (0xCC)、白
4. **所有尺寸走 `UI.sz()`**：保证不同 DPI 和用户字号偏好下的一致性

---

## 配置系统

### 存储路径

```text
$KOREADER_DATA/.moon/settings/config.lua
```

使用 KOReader 的 `LuaSettings` 序列化（Lua table → 文件）。

### 配置字段

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `base_url` | string | `""` | 服务器地址 |
| `token` | string | `""` | Bearer 令牌 |
| `library_dir` | string | `$DATA/books` | 本地下载缓存目录 |
| `auto_sync` | boolean | `true` | 自动同步进度 |
| `auto_stats` | boolean | `true` | 自动上报阅读统计 |
| `open_on_start` | boolean | `true` | 启动时打开桌面 |
| `home_header` | string | `"clock"` | 主页顶部：`"clock"` 或 `"hitokoto"` |
| `ui_scale` | number | `130` | 界面缩放百分比 (100–180) |
| `reader_float_menu` | boolean | `true` | 阅读页悬浮菜单 |

### 迁移机制

首次打开新配置文件时，自动从 `G_reader_settings` 的旧键 `book_plugin_v2` / `book_plugin` 迁移，迁移后删除旧键。

---

## 编码规范

### Lua 风格

```lua
-- 局部变量用 local，模块顶部 require
local UIManager = require("ui/uimanager")
local logger = require("logger")

-- 模块导出：table 或 class
local MyModule = {}
-- 或
local MyClass = InputContainer:extend{ name = "my_class" }

-- 函数命名：小驼峰（KOReader 事件用 on 前缀）
function MyClass:buildContent()
function MyClass:onTapSomething()

-- 私有函数：模块级 local function
local function helperFunc()
```

### require 路径

```lua
-- KOReader 内置模块：直接用 KOReader 的路径
local Device = require("device")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")

-- 插件内部模块：直接用文件名（KOReader 把插件目录加入了 package.path）
local Api = require("api")
local Cover = require("cover")
local UI = require("bookui")

-- 子目录模块：用 . 分隔
local MoonSettings = require("moon.settings")
local Settings = require("moon.ui.settings")
```

### 错误处理

```lua
-- 对外部调用/可能不存在的模块用 pcall
local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
if ok then ScrollableContainer = mod end

-- API 调用返回 (data, err) 双值
local res, err = api:listBooks(opts)
if not res then
    -- err 是人类可读的错误信息
    UIManager:show(InfoMessage:new{ text = err })
    return
end
```

### 国际化

```lua
local _ = require("gettext")
local T = require("ffi/util").template

-- 简单字符串
local text = _("已保存")

-- 带参数模板
local text = T(_("连接成功：%1"), name)
```

### 图标

所有图标放在 `icons/` 目录，使用 SVG 格式。加载方式统一：

```lua
local function pluginIconDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("(.*/)") 
        if dir then return dir .. "icons/" end
    end
    return "icons/"
end

-- 用 ImageWidget 加载
ImageWidget:new{
    file = pluginIconDir() .. "home.svg",
    width = UI.iconSz(),
    height = UI.iconSz(),
    alpha = true,
}
```

### 关键约定

1. **所有尺寸走 `UI.sz()`**，不要硬编码像素值
2. **所有字号走 `UI.fontSize()` 或 `UI.face()`**
3. **所有颜色走 `UI.ink()`、`UI.muted()` 等色阶函数**
4. **封面渲染必须走 `Cover.widget()`**，禁止直接 `ImageWidget{file=, scale_factor=0}`
5. **页面模块导出 `Module.build(ctx)` 函数**，返回 widget 树
6. **配置读写一律走 `MoonSettings`**，不要直接操作 `G_reader_settings`（filemap/metamap 除外）

---

## 构建与发布

### 本地打包

```bash
# 手动打 zip（不含 koreader 子模块、screenshots、.git 等）
zip -r book.koplugin.zip book.koplugin \
    -x "*.DS_Store" -x "*/.DS_Store" -x "*~"
```

### CI 发布（GitHub Actions）

工作流：`.github/workflows/release.yml`

触发条件：推送 `v*` 标签（如 `v1.2.3`）。

流程：

1. Checkout 代码
2. 从 tag 解析版本号（校验 `vMAJOR.MINOR.PATCH` 格式）
3. 注入版本到 `bookversion.lua`：`printf 'return "%s"\n' "$VERSION" > book.koplugin/bookversion.lua`
4. 打包 `book.koplugin-vX.Y.Z.zip`
5. 自动生成 Release Notes（按 commit 分组：feat/fix/style/perf/refactor/docs/chore）
6. 创建 GitHub Release（含预发布判断：版本号含 `-` 则标记 prerelease）

### 版本号注入

`bookversion.lua` 的设计：

- 开发时返回 `"0.0.0-dev"`（`@VERSION@` 占位符未替换时的兜底）
- CI 直接整文件覆盖为 `return "X.Y.Z"`
- 模块名故意用 `bookversion` 而非 `version`，避免与 KOReader 自带模块冲突

---

## 开发环境搭建

### 1. 克隆仓库

```bash
git clone --recurse-submodules https://github.com/AnkioTomas/moon.git
cd moon
```

若已克隆但子模块为空：

```bash
git submodule update --init --recursive
```

`koreader/` 子模块用途：

- IDE 代码补全与跳转
- 本机编译并运行 KOReader 模拟器（Mac / Linux）

插件发布物仍只有 `book.koplugin/`，不会把 `koreader/` 打进包。

网络不稳定时（尤其国内拉 GitHub），可临时开代理后再拉子模块：

```bash
export all_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
git submodule update --init --recursive
```

### 2. IDE 配置

推荐使用支持 Lua 的 IDE（IntelliJ + Lua 插件、VS Code / Cursor + Lua Language Server）。

将以下路径加入 Lua 源码搜索路径：

- `koreader/frontend/` — KOReader 核心框架
- `koreader/plugins/` — KOReader 内置插件（参考实现）
- `book.koplugin/` — 本插件

### 3. 挂接插件（软链接）

开发时不要复制目录，用软链接，改 Lua 后重启模拟器即可生效。

```bash
# 在仓库根目录执行；目标必须是插件目录本身
ln -sfn "$(pwd)/book.koplugin" "$(pwd)/koreader/plugins/book.koplugin"
ls -la koreader/plugins/book.koplugin
```

`./kodev build` / `./kodev run` 会把源码树里的 `plugins/` 链进模拟器安装目录，因此这个软链接会被模拟器直接加载。

### 4. macOS：编译并运行模拟器

官方说明见 [KOReader Building.md](https://github.com/koreader/koreader/blob/master/doc/Building.md)。以下是本仓库验证过的最短路径。

#### 4.1 依赖

```bash
brew install autoconf automake bash binutils cmake coreutils findutils \
  gettext gnu-getopt libtool make meson nasm ninja pkgconf sdl3 \
  util-linux wget
```

macOS 自带 bash 是 3.x，`./kodev` 要求 **bash ≥ 4**。把 Homebrew 的 GNU 工具放进 `PATH`（可写入 `~/.zshrc`）：

```bash
export PATH="$(brew --prefix)/opt/bash/bin:$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/opt/gnu-getopt/bin:$(brew --prefix)/opt/make/libexec/gnubin:$(brew --prefix)/opt/util-linux/bin:${PATH}"
```

确认：

```bash
bash --version   # >= 4.0
make --version   # GNU Make
which wget
```

拉依赖 / 编译时若访问 GitHub 失败，同样先导出上面的 `all_proxy` / `http_proxy` / `https_proxy`。

#### 4.2 拉取第三方并编译

```bash
cd koreader
./kodev fetch-thirdparty
./kodev build
```

首次编译会下载并构建大量第三方库，耗时较长，属正常。

#### 4.3 运行

```bash
./kodev run
# 或模拟墨水屏尺寸：
./kodev run -s=kobo-aura-one
```

启动后从主菜单打开 **Book 桌面**。日志应出现：

```text
RD loaded plugin book at plugins/book.koplugin
```

日常迭代：改 `book.koplugin/` → 关掉模拟器窗口 → 再执行 `./kodev run`。软链接保证源码改动直接生效；`require` 有缓存，**必须重启**，热重载不可用。

### 5. 真机 / 已安装 KOReader 上测试

将 `book.koplugin/` 复制或软链接到设备上的 KOReader `plugins/` 目录后重启：

```bash
# 示例：链到本机已安装的 KOReader 数据目录
ln -sfn /path/to/moon/book.koplugin /path/to/koreader/plugins/book.koplugin
```

---

## 调试

### 日志

```lua
local logger = require("logger")

logger.info("book something happened", value)   -- 普通日志
logger.warn("book something wrong", err)         -- 警告
logger.err("book fatal", err)                    -- 错误
logger.dbg("book debug detail", data)            -- 调试（需开启 verbose）
```

日志前缀统一用 `"book"` 或 `"book.模块名"`，便于 grep。

### KOReader 日志查看

```bash
# Kindle
cat /mnt/us/koreader/crash.log

# Kobo
cat /mnt/onboard/.adds/koreader/crash.log

# macOS / Linux 模拟器（./kodev run）
# 日志直接打到启动该命令的终端 stdout
```

### 常见陷阱

1. **`require` 缓存**：Lua 的 `require` 有全局缓存，修改代码后必须重启 KOReader
2. **触摸热区冲突**：`overrides` 数组决定手势优先级，忘了覆盖会被底层翻页拦截
3. **封面 OOM**：直接用 `ImageWidget{file=, scale_factor=0}` 会把原图像素全部加载进内存，图书馆一页就 OOM
4. **HTTPS**：必须 `pcall(require, "ssl.https")` 拉起 SSL 模块，否则 HTTPS 请求会拿到垃圾响应
5. **`os.rename` 跨设备**：部分设备 `/tmp` 和 SD 卡不在同一文件系统，`os.rename` 会失败，需要回退到读写复制
6. **macOS `./kodev` 报 bash 版本过旧**：系统 `/bin/bash` 是 3.2，必须让 Homebrew `bash` 排在 `PATH` 前面
7. **编译缺 `wget`**：第三方下载脚本硬依赖 `wget`，不是 `curl`；`brew install wget`
8. **子模块拉到一半失败**：清掉残缺目录后带代理重试 `git submodule update --init --force -- <path>`

---

## 提交规范

使用 Conventional Commits + emoji 前缀（CI Release Notes 自动分组）：

| 前缀 | 分组 | 示例 |
|------|------|------|
| `feat:` / `:sparkles:` | 新功能 | `feat: 添加按作者筛选` |
| `fix:` / `:bug:` | 修复 | `fix: 封面缓存未命中时崩溃` |
| `style:` / `:lipstick:` | 界面 | `:lipstick: 统计页日历对齐` |
| `perf:` / `:zap:` | 性能 | `perf: 封面解码降低内存占用` |
| `refactor:` / `:recycle:` | 重构 | `refactor: 提取 bookui 缩放函数` |
| `docs:` / `:memo:` | 文档 | `docs: 更新 API 接口说明` |
| `chore:` / `:wrench:` | 其他 | `chore: 升级 CI workflow` |

---

## 许可证

[MIT License](LICENSE)
