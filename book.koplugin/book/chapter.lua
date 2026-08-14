--[[--
按章阅读会话：materialize / goto / 前1后3 预取。

@module koplugin.book.book.chapter
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Store = require("book.store")
local Promise = require("utils.promise")
local SourceError = require("source.error")
local Content = require("book.content")
local Contract = require("source.contract")
local _ = require("gettext")

local Chapter = {
    _session = nil,
}

--- 取当前按章阅读会话。
---@return table|nil
local function session()
    return Chapter._session
end

--- 是否有有效按章会话。
---@return boolean
function Chapter.isActive()
    local s = session()
    return s ~= nil and s.ref ~= nil
end

--- 当前会话目录章数。
---@return number|nil
function Chapter.chapterCount()
    local s = session()
    if not s or type(s.toc) ~= "table" then
        return nil
    end
    return #s.toc
end

--- 当前章节序号。
---@return number|nil
function Chapter.currentIdx()
    local s = session()
    return s and s.idx or nil
end

--- 当前会话目录。
---@return BookChapter[]|nil
function Chapter.toc()
    local s = session()
    return s and s.toc or nil
end

--- 当前会话 BookRef。
---@return BookRef|nil
function Chapter.ref()
    local s = session()
    return s and s.ref or nil
end

--- 绑定按章阅读会话。
---@param opts table
function Chapter.bind(opts)
    Chapter._session = {
        plugin = opts.plugin,
        source = opts.source,
        book = opts.book,
        ref = opts.ref,
        toc = opts.toc,
        idx = opts.idx or 1,
        generation = opts.generation or 0,
    }
end

--- 清除按章阅读会话。
function Chapter.clear()
    Chapter._session = nil
end

--- 拉/缓存目录（同步 worker）
---@param source BookSource
---@param ref BookRef
---@return BookChapter[]|nil, any
function Chapter.loadToc(source, ref)
    require("utils.promise").requireAsync("book.chapter.loadToc")
    local cached = Store.getToc(ref.book_key)
    if cached and cached.chapters and #cached.chapters > 0 then
        return cached.chapters
    end
    if not source or not source.getToc then
        return nil, SourceError.unsupported(_("数据源不支持目录"))
    end
    local chapters, err = source:getToc(ref)
    if not chapters then
        return nil, err
    end
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil, SourceError.not_found(_("目录为空"))
    end
    local normalized = {}
    for i, ch in ipairs(chapters) do
        normalized[#normalized + 1] = {
            idx = tonumber(ch.idx) or i,
            source_idx = ch.source_idx,
            uid = ch.uid,
            title = (ch.title and ch.title ~= "") and ch.title or tostring(i),
        }
    end
    Store.putToc(ref.book_key, { chapters = normalized }, ref.source_id)
    return normalized
end

--- 异步拉/缓存目录；回调 cb(ok, chapters, err)。
---@param source BookSource
---@param ref BookRef
---@param cb fun(ok: boolean, chapters: BookChapter[]|nil, err: any)
function Chapter.loadTocAsync(source, ref, cb)
    if type(cb) ~= "function" then
        return
    end
    local cached = Store.getToc(ref.book_key)
    if cached and cached.chapters and #cached.chapters > 0 then
        UIManager:nextTick(function()
            cb(true, cached.chapters)
        end)
        return
    end
    Promise:new(function()
        local toc, err = Chapter.loadToc(source, ref)
        if not toc then
            return nil, err or _("无法获取目录")
        end
        return toc
    end)
        :next(function(toc)
            cb(true, toc)
        end)
        :fail(function(err)
            cb(false, nil, err or _("无法获取目录"))
        end)
end

--- 按 idx 在目录中找章节；找不到则回退 toc[idx]。
---@param toc BookChapter[]|nil
---@param idx number
---@return BookChapter|nil
local function findChapter(toc, idx)
    if type(toc) ~= "table" then
        return nil
    end
    for _, c in ipairs(toc) do
        if tonumber(c.idx) == idx then
            return c
        end
    end
    return toc[idx]
end

--- 确保章节 epub（写 .part 再改名由 source 负责；此处 temp=final.part）
---@param source BookSource
---@param ref BookRef
---@param idx number|string
---@param toc BookChapter[]|nil
---@return string|nil, any
function Chapter.ensure(source, ref, idx, toc)
    require("utils.promise").requireAsync("book.chapter.ensure")
    idx = tonumber(idx) or 1
    local path = Store.chapterPath(ref.book_key, idx, ref.source_id)
    if Content.isValidEpub(path) then
        return path
    end
    pcall(os.remove, path)
    if not source or not source.materializeChapter then
        return nil, SourceError.unsupported(_("数据源不支持按章下载"))
    end
    toc = toc or (Store.getToc(ref.book_key) and Store.getToc(ref.book_key).chapters)
    local ch = findChapter(toc, idx)
    if not ch then
        ch = { idx = idx, title = tostring(idx) }
    end
    local tmp = path .. ".part"
    local ok, err = source:materializeChapter(ref, ch, tmp)
    if not ok then
        pcall(os.remove, tmp)
        return nil, err
    end
    if not Content.isValidEpub(tmp) then
        pcall(os.remove, tmp)
        return nil, SourceError.io(_("章节文件校验失败"))
    end
    os.remove(path)
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return nil, SourceError.io(_("无法保存章节文件"))
    end
    if not Content.isValidEpub(path) then
        return nil, SourceError.io(_("章节文件未生成"))
    end
    return path
end

--- 异步确保章节 epub；回调 cb(ok, path, err)。
---@param source BookSource
---@param ref BookRef
---@param idx number|string
---@param toc BookChapter[]|nil
---@param cb fun(ok: boolean, path: string|nil, err: any)
function Chapter.ensureAsync(source, ref, idx, toc, cb)
    if type(cb) ~= "function" then
        return
    end
    idx = tonumber(idx) or 1
    local path = Store.chapterPath(ref.book_key, idx, ref.source_id)
    if Content.isValidEpub(path) then
        UIManager:nextTick(function()
            cb(true, path)
        end)
        return
    end
    Promise:new(function()
        local p, err = Chapter.ensure(source, ref, idx, toc)
        if not p then
            return nil, err or _("章节下载失败")
        end
        return p
    end)
        :next(function(p)
            cb(true, p)
        end)
        :fail(function(err)
            cb(false, nil, err or _("章节下载失败"))
        end)
end

--- 打开/切换到章节文件阅读器。
---@param path string
local function showReader(path)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if ui and ui.switchDocument then
        ui:switchDocument(path)
        return
    end
    UIManager:nextTick(function()
        ReaderUI:showReader(path)
    end)
end

--- 跳转到指定章节（缓存命中则立即打开，否则联网下载）。
---@param idx number|string
---@param opts table|nil
---@return boolean, string|nil
function Chapter.gotoChapter(idx, opts)
    local s = session()
    if not s or not s.ref then
        return false, _("无章节会话")
    end
    idx = tonumber(idx) or 1
    local count = Chapter.chapterCount() or 0
    if idx < 1 or (count > 0 and idx > count) then
        return false, _("章节越界")
    end
    local source = s.source
    local ref = s.ref

    --- 登记打开并进入阅读器。
    ---@param path string
    ---@return boolean
    local function openPath(path)
        s.idx = idx
        Store.touch(path, ref, { chapter_idx = idx })
        showReader(path)
        Chapter.prefetchAround(idx)
        return true
    end

    local path = Store.chapterPath(ref.book_key, idx, ref.source_id)
    if Content.isValidEpub(path) then
        return openPath(path)
    end

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{ text = _("正在加载章节…"), timeout = 1 })
        Chapter.ensureAsync(source, ref, idx, s.toc, function(ok, p, err)
            if not ok or not p then
                UIManager:show(InfoMessage:new{ text = SourceError.message(err) or err or _("章节下载失败") })
                return
            end
            openPath(p)
        end)
    end)
    return true
end

--- 下一章。
---@return boolean, string|nil
function Chapter.next()
    local idx = Chapter.currentIdx()
    if not idx then
        return false
    end
    return Chapter.gotoChapter(idx + 1)
end

--- 上一章。
---@return boolean, string|nil
function Chapter.prev()
    local idx = Chapter.currentIdx()
    if not idx then
        return false
    end
    return Chapter.gotoChapter(idx - 1)
end

--- 预取当前章前后（前 1 后 3）。
---@param idx number|string|nil
function Chapter.prefetchAround(idx)
    local s = session()
    if not s or not s.ref then
        return
    end
    idx = tonumber(idx) or s.idx or 1
    local count = Chapter.chapterCount() or 0
    local targets = {}
    if idx - 1 >= 1 then
        targets[#targets + 1] = idx - 1
    end
    for d = 1, 3 do
        if idx + d <= count then
            targets[#targets + 1] = idx + d
        end
    end
    local source = s.source
    local ref = s.ref
    local toc = s.toc
    for _, tidx in ipairs(targets) do
        local path = Store.chapterPath(ref.book_key, tidx, ref.source_id)
        if not Content.isValidEpub(path) then
            Chapter.ensureAsync(source, ref, tidx, toc, function(ok, p, err)
                if not ok then
                    logger.dbg("book.chapter prefetch fail", tidx, SourceError.message(err))
                else
                    logger.dbg("book.chapter prefetch ok", tidx, p)
                end
            end)
        end
    end
end

--- 异步准备按章打开；回调 cb(ok, prep, err)，prep = { book, toc, start_idx }。
---@param source BookSource
---@param book Book
---@param ref BookRef
---@param cb fun(ok: boolean, prep: table|nil, err: any)
function Chapter.prepareOpenAsync(source, book, ref, cb)
    if type(cb) ~= "function" then
        return
    end
    Promise:new(function()
        local b = book
        if source.getDetail then
            local detail = source:getDetail(ref)
            if detail then
                Store.remember(detail)
                b = detail
            end
        end
        return b
    end)
        :next(function(book2)
            book2 = book2 or book
            Chapter.loadTocAsync(source, ref, function(tok, toc, terr)
                if not tok or not toc or #toc == 0 then
                    cb(false, nil, terr or _("无法获取目录"))
                    return
                end
                Promise:new(function()
                    local start_idx = 1
                    if source.getProgress then
                        local pos = source:getProgress(ref)
                        if pos then
                            start_idx = tonumber(pos.chapter_idx) or start_idx
                            if not pos.chapter_idx then
                                local pct = Contract.clampFraction(pos.fraction)
                                local count = #toc
                                if count > 0 and pct > 0 then
                                    start_idx = math.max(1, math.min(count, math.floor(pct * count) + 1))
                                end
                            end
                        end
                    end
                    return start_idx
                end)
                    :next(function(start_idx)
                        cb(true, {
                            book = book2,
                            toc = toc,
                            start_idx = tonumber(start_idx) or 1,
                        })
                    end)
                    :fail(function(perr)
                        cb(false, nil, perr or _("准备失败"))
                    end)
            end)
        end)
        :fail(function(err)
            cb(false, nil, err or _("准备失败"))
        end)
end

--- 弹出目录菜单并跳转选中章。
---@return boolean
function Chapter.showTocMenu()
    local s = session()
    if not s or type(s.toc) ~= "table" then
        return false
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local buttons = {}
    local cur = s.idx or 1
    for _, ch in ipairs(s.toc) do
        local i = tonumber(ch.idx) or 0
        local title = (ch.title or ("#" .. i))
        if i == cur then
            title = "• " .. title
        end
        buttons[#buttons + 1] = {
            {
                text = title,
                callback = function()
                    if Chapter._toc_dialog then
                        UIManager:close(Chapter._toc_dialog)
                        Chapter._toc_dialog = nil
                    end
                    Chapter.gotoChapter(i)
                end,
            },
        }
    end
    Chapter._toc_dialog = ButtonDialog:new{
        title = _("目录"),
        buttons = buttons,
    }
    UIManager:show(Chapter._toc_dialog)
    return true
end

return Chapter
