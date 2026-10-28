--[[--
月读第三方书源示例：一本三章的静态书，不联网。契约就写在本文件头注释里。

KOReader 加载完全部插件后，月读在首次访问源注册表时 dofile 本文件，此时所有插件目录都已在 package.path 上，
可以直接 require 月读的 source.base / source.chapter / source.shelf / source.toc。
自己的子模块放进带唯一前缀的目录（如 moonsource_demo/client.lua → require("moonsource_demo.client")），
别用 client / utils 这类通用名：所有插件共用一个 package.path，同名模块谁先加载算谁的。

契约（月读扩展 = 独立 KOReader 插件：_meta.lua、返回空 WidgetContainer 的 main.lua、本文件）：
- 扩展自己声明能力：描述表 { api, provides = { source = true|false, home_widgets = {...} }, ... }。
  有 provides 时只有 source == true 才是书源；没有 provides 的旧描述文件默认是书源（顶层 source = false 除外），
  首页组件取顶层 home。不是书源的扩展（只加首页组件等）写 { api, id = "ext.<name>", provides = { source = false, home_widgets = {...} } }，
  不需要 meta / new，完整示例见 examples/moonwidget-demo.koplugin。
- 书源描述表 { api, provides?, meta, new, setting? }。api 必须等于月读的 Registry.API；meta() 无 IO；new() 返回继承 source.base 的实例。
- id 必须是 ext.<name>（字母数字 _-），写进书库和配置文件名，发布后不能改；重名时先加载的生效。不合约定只记日志不加载。
- type 只有 book（交整本文件）和 chapter（按章交 HTML）。Book 至少有 source_id / stable_id / title，stable_id 同样不能改。
- 至少实现 configured()、syncBooksAsync（快照交 source.shelf.reconcile；dirty_only 无删除接口就 skipped）、
  openBookAsync（book：下载后 book.store.touch 再回调路径；chapter：source.chapter.openWithUi；自己展示了就 cb(nil, nil, { handled = true })）、
  chapter 型的 loadTocAsync（source.toc 缓存）。可选：getDetailAsync、prefetch / cacheAllChaptersAsync、get/putProgressAsync、
  push/pullNotesAsync（私有字段要活过保存再实现 cleanAnnotations / prepareLocalAnnotations）、pushStatsAsync、coverRequest、onEvent、close。
- 只依赖这些月读模块：source.base / shelf / chapter / toc、book.store（touch、rememberMany）、book.books_db（只读）、
  book.progress_db（get、upsertRemote）、book.note.normalize、utils.paths / settings / log / text、http.request、
  ui.themes.widgets.*、ui.widgets.book、desktop.pages.home.base。顶层不 require KOReader UI，离线判断用 isConnected。
- setting：rows(plugin) 自画整节，或 open(plugin) + 可选 rowStatus / rowTitle / rowIcon；remote 字段数组会出现在远程管理「连接配置」（secret = true 脱敏）。
- home_widgets（旧写法 home）：首页组件数组，出现在首页编辑的「添加组件」里，跟内置组件一样摆放。两种写法：
  · 简写表 { id, title, build = fun(ctx, w, h): widget, icon?, height? 或 heightRange = fun(ctx, opts): { height }, settings? = fun(desktop, id) }，
    id 可只写短名，月读补成 <扩展 id>.<短名>；build 用 ui.themes.widgets.* 拼控件，返回的控件占满 w × h。
  · 完整组件类：继承 desktop.pages.home.base，id 写全名 <扩展 id>.<名>，请求在 onActivate 发、onDeactivate 取消。
  组件代码出错只记日志、画空白，不影响首页；id 不以 <扩展 id>. 开头或重名的不加载。
  插件卸载 / 禁用后组件不显示，首页布局里的位置保留，重装后回到原处。
- features（可选）：往月读自己的挂点加功能 { setting, panel, topbar, events, hooks = { onReaderReady }, lookup }，
  值是表或插件内模块名（延迟 require），形状同 features/<name>/ 下的约定文件；契约见 book.koplugin/features/init.lua 头注释，
  示例见 examples/moonwidget-demo.koplugin。lookup = { tabs?, actions? }：tabs 往查词面板底部加 Tab
  { id, text, icon?, fetch }，fetch(text, { ui, context, from_highlight }, cb) 异步交回 cb(正文|nil, 错误|nil)，可返回 { cancel = fn }；
  actions 往操作行（复制旁）追加按钮 { id, text, run, available? }，ctx = { text, content, active, ui, from_highlight, close? }；
  不写就不追加；id 由月读补成 <扩展 id>.<id>。
- 新装默认启用；卸载后若是当前源退回本地，书留在书库不显示，重装同一 id 恢复。
--]]

local SourceBase = require("source.base")
local _ = require("gettext")

local ID = "ext.demo"

local TOC = {
    { idx = 1, uid = "c1", title = _("第一章 起") },
    { idx = 2, uid = "c2", title = _("第二章 承") },
    { idx = 3, uid = "c3", title = _("第三章 合") },
}

--- 书架快照里的一本书。每次新建：书库对账会就地补字段。
---@return Book
local function demoBook()
    return {
        source_id = ID,
        stable_id = "demo-1",
        title = _("月读示例书"),
        authors = _("月读"),
        intro = _("第三方书源示例：三章静态正文，不联网。"),
    }
end

---@class DemoSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

function Source:configured()
    return true
end

--- 书架：拉远端快照交给书库对账。示例没有远端删除接口，dirty_only（只推本地删改）直接跳过，
--- 删掉的书留墓碑，对账不会让它复活。
---@param opts { dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    if opts and opts.dirty_only then
        return SourceBase.skipped(cb, "no remote shelf")
    end
    local result, err = require("source.shelf").reconcile(self.id, { demoBook() })
    return SourceBase.defer(cb, result, err)
end

function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or demoBook())
end

--- 目录写进书库缓存：离线打开已下载章节、阅读页目录都读这份。
function Source:loadTocAsync(identity, cb)
    if not require("source.toc").put(self.id, identity.stable_id, TOC) then
        return SourceBase.defer(cb, nil, _("章节目录保存失败"))
    end
    return SourceBase.defer(cb, TOC)
end

--- 一章正文。真实书源在这里发 HTTP（月读的 http/request），交回 { title, html } 或 { title, text }。
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchContent(_identity, chapter, cb)
    return SourceBase.defer(cb, {
        title = chapter.title,
        text = chapter.title .. "\n" .. _("这是示例书源交给月读的纯文本正文，月读负责排成段落、落盘和登记。"),
    })
end

--- 按章打开：带进度窗；切章（opts.chapter_idx）不弹窗。
function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = fetchContent,
    }, cb)
end

--- 阅读中预取后面几章。
function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = fetchContent,
    }, cb)
end

---@return BookSourceMeta
local function meta()
    return { id = ID, name = _("示例书源"), type = "chapter" }
end

--- 首页组件（简写表）：一行提示，点一下打开示例书。
local hello = {
    id = "hello", -- 月读补成 ext.demo.hello
    title = _("示例书源提示"),
    icon = "menu_book",
    build = function(ctx, w, h)
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local Tap = require("ui.themes.widgets.tap")
        local Text = require("ui.themes.widgets.text")
        local label = Text.line("body", _("来自示例书源的首页组件 · 点我打开示例书"), { width = w })
        return Tap.wrap(CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, label }, function()
            require("desktop.pages.home.base").openBook(ctx, demoBook())
        end)
    end,
    heightRange = function()
        return { height = require("ui.themes.widgets.text").line("body", "国"):getSize().h * 2 }
    end,
}

return {
    api = 1,
    provides = { source = true, home_widgets = { hello } },
    meta = meta,
    new = function()
        return setmetatable(meta(), Source)
    end,
}
