--[[--
月读第三方书源示例：一本三章的静态书，不联网。契约见月读仓库 docs/source/external.md。

KOReader 加载完全部插件后，月读在首次访问源注册表时 dofile 本文件，此时所有插件目录都已在 package.path 上，
可以直接 require 月读的 source.base / source.chapter / source.shelf / source.toc。
自己的子模块放进带唯一前缀的目录（如 moonsource_demo/client.lua → require("moonsource_demo.client")），
别用 client / utils 这类通用名：所有插件共用一个 package.path，同名模块谁先加载算谁的。
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

return {
    api = 1,
    meta = meta,
    new = function()
        return setmetatable(meta(), Source)
    end,
}
