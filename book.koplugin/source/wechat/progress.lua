--[[--
微信进度坐标：chapterOffset 是章节原文的字符偏移，EPUB 含 HTML 标签，TXT 按纯文本计。
原文随章节缓存，离线进度仍只保存本地 XPointer；联网推送时转换，不把页比例当成字符坐标。

localize 得到的字符比例只进 extra.chapter_char_fraction，**不写** ProgressPosition.chapter_fraction：
后者是阅读器章内页比例（DocumentToc），混进同一字段会让开书比对假冲突、静默跟云端、
以及 locator 失效时把字符比当成页比例 gotoFraction —— 体感就是进度跳来跳去。

@module koplugin.book.source.wechat.progress
--]]

local Annotations = require("book.annotations")
local JSON = require("json")
local Paths = require("utils.paths")
local Text = require("utils.text")
require("l10n").apply()
local _ = require("gettext")

local Position = {}

local function cachePath(book_id, idx)
    return Paths.bookWorkDir(book_id, "wechat") .. "/" .. idx .. ".position.json"
end

---@param book_id string
---@param chapter BookChapter
---@param source string
---@param format '"html"'|'"txt"'
---@return boolean|nil, string|nil
function Position.remember(book_id, chapter, source, format)
    local path = cachePath(book_id, chapter.idx)
    local ok, err = Paths.ensureDir(path:match("(.+)/[^/]+$"))
    if not ok then return nil, err end
    local f
    f, err = io.open(path .. ".part", "wb")
    if not f then return nil, err end
    local written, write_err = f:write(JSON.encode({ uid = chapter.uid, source = source, format = format }))
    local closed, close_err = f:close()
    if not written or not closed then
        os.remove(path .. ".part")
        return nil, write_err or close_err
    end
    local renamed, rename_err = os.rename(path .. ".part", path)
    if not renamed then os.remove(path .. ".part"); return nil, rename_err end
    return true
end

---@param identity BookIdentity
---@param chapter BookChapter
---@param cb fun(source: string|nil, format_or_error: string|nil)
---@return { cancel: fun() }|nil
function Position.loadAsync(identity, chapter, cb)
    local f = io.open(cachePath(identity.stable_id, chapter.idx), "rb")
    if f then
        local raw = f:read("*a")
        f:close()
        local data = JSON.decode(raw)
        if data.uid == chapter.uid then
            cb(data.source, data.format)
            return nil
        end
    end
    return require("source.wechat.chapter").fetchHtmlAsync(identity.stable_id, chapter,
        function(_html, err, source, format)
            if not source then cb(nil, err); return end
            local ok, cache_err = Position.remember(identity.stable_id, chapter, source, format)
            if not ok then cb(nil, cache_err); return end
            cb(source, format)
        end)
end

local function localHtml(identity, chapter, source, format)
    local f = io.open(Paths.chapterPath(identity.stable_id, chapter.idx, identity.source_id), "rb")
    if f then
        local html = f:read("*a")
        f:close()
        return html
    end
    if format == "html" then return source end
    return require("source.chapter").render({
        title = chapter.title,
        html = "<h1>" .. Text.xmlEscape(chapter.title or "") .. "</h1>" .. Text.textToBody(source),
    })
end

---@param identity BookIdentity
---@param chapter BookChapter
---@param pos ProgressPosition
---@param source string
---@param format '"html"'|'"txt"'
---@return boolean|nil, string|nil
function Position.localize(identity, chapter, pos, source, format)
    local wire = Annotations.rangeMapping(source, format)
    local flow = Annotations.flow(localHtml(identity, chapter, source, format))
    local locator, fraction = Annotations.fromWireOffset(wire, flow, pos.extra.chapter_offset)
    if not locator then return nil, _("无法定位阅读进度") end
    pos.locator = locator
    pos.extra.chapter_char_fraction = fraction
    -- 有精确定位就不填页比例字段；打开文档后由 Toc.chapterFraction 重算。
    pos.chapter_fraction = nil
    return true
end

---@param identity BookIdentity
---@param chapter BookChapter
---@param pos ProgressPosition
---@param source string
---@param format '"html"'|'"txt"'
---@return integer|nil offset
---@return string|nil summary
---@return number|nil fraction
---@return string|nil err
function Position.encode(identity, chapter, pos, source, format)
    local wire = Annotations.rangeMapping(source, format)
    if not pos.locator then
        if pos.chapter_fraction == 1 then
            return wire.ends[wire.count] or 0, "", 1
        end
        if pos.chapter_fraction == 0 then return 0, "", 0 end
        return nil, nil, nil, _("无法定位阅读进度")
    end
    return Annotations.toWirePosition(wire,
        Annotations.flow(localHtml(identity, chapter, source, format)), pos.locator)
end

return Position
