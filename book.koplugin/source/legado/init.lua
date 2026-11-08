--[[--
阅读（Legado / 开源阅读）数据源。

直连阅读 App 的 Web 服务，或 reader3 服务器版（地址可带 /reader3 前缀，再配账号密码，setting.lua 配置）。书架只拉不加（书在阅读 App 里添加），
目录 / 正文按章落盘走公共 source/chapter；进度只到章，开书从书架行的 durChapterIndex 拉，
关书经 /saveBookProgress 上报。笔记和统计没有接口。

@module koplugin.book.source.legado
--]]

local Client = require("source.legado.client")
local Mapper = require("source.legado.mapper")
local Text = require("utils.text")
local Request = require("http.request")
local Assets = require("source.assets")
local Paths = require("utils.paths")
local Shelf = require("source.shelf")
local SourceBase = require("source.base")
local Toc = require("source.toc")
local _ = require("l10n").get("source.legado")

local Legado = {}

---@return BookSourceMeta
function Legado.meta()
    return SourceBase.loadMeta("legado")
end

---@class LegadoSource : SourceBase
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return LegadoSource
function Legado.new()
    local meta = Legado.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

---@return boolean
function Source:configured()
    return Client.base() ~= nil
end

---@param rows table[]
---@param stable_id string
---@return table|nil
local function findRow(rows, stable_id)
    for _idx, row in ipairs(rows) do
        if row.bookUrl == stable_id then return row end
    end
    return nil
end

--- 书架远端：Shelf.syncAsync 要的三个冒号方法。书只能在阅读 App 里加，本地没有「加入」入口。
local Remote = {}

function Remote:shelfSyncAsync(cb) return Client.shelfAsync(cb) end

function Remote:addToShelfAsync(_stable_id, cb)
    return SourceBase.defer(cb, nil, _("请在阅读 App 里添加书籍"))
end

--- 远端已经没有这本书就算删除完成。
function Remote:removeFromShelfAsync(stable_id, cb)
    local cancelled, job = false, nil
    job = Client.shelfAsync(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, stable_id)
        if not row then cb(true); return end
        job = Client.deleteBookAsync(row, cb)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:syncBooksAsync(opts, cb)
    if not self:configured() then return SourceBase.skipped(cb, "legado not configured") end
    return Shelf.syncAsync(self.id, Remote, function(rows) return Mapper.shelfList(Client.coverUrl, rows) end, opts, cb)
end

--- 取书架行再交给 fn(row, toc, done)；没配置 / 不在书架上 / 目录空都走 cb 报错。
--- fn 要再发请求就返回它的句柄，取消会传过去；done 是取消后不再投递的 cb。
---@param identity BookIdentity
---@param cb function
---@param fn fun(row: table, toc: BookChapter[], done: function): { cancel: fun() }|nil
---@return { cancel: fun() }
function Source:withRow(identity, cb, fn)
    if not self:configured() then return SourceBase.defer(cb, nil, _("未配置阅读服务器地址")) end
    local cancelled, job = false, nil
    local function done(...)
        if not cancelled then cb(...) end
    end
    job = Client.shelfAsync(function(rows, err)
        if cancelled then return end
        if not rows then cb(nil, err); return end
        local row = findRow(rows, identity.stable_id)
        if not row then cb(nil, _("这本书不在阅读书架上")); return end
        job = self:loadTocAsync(identity, function(toc, reason)
            if cancelled then return end
            if not toc then cb(nil, reason); return end
            job = fn(row, toc, done) or job
        end)
    end)
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

function Source:getProgressAsync(identity, cb)
    return self:withRow(identity, cb, function(row, toc)
        local read = Mapper.readPos(row)
        if not read then cb(nil, nil, { empty = true }); return end
        local idx = math.min(read.index + 1, #toc)
        cb({
            chapter_idx = idx,
            chapter_title = read.title or toc[idx].title,
            fraction = (idx - 1) / #toc,
            extra = { chapter_uid = toc[idx].uid, chapter_idx = idx },
        })
    end)
end

function Source:putProgressAsync(identity, pos, cb)
    return self:withRow(identity, cb, function(row, toc, done)
        local idx = tonumber(pos.chapter_idx) or tonumber(identity.chapter_idx)
        local chapter = idx and toc[idx]
        if not chapter then cb(nil, _("缺少阅读章节位置")); return end
        local read = Mapper.readPos(row)
        local same = read and read.index == idx - 1
        return Client.saveProgressAsync(row, {
            index = idx - 1,
            title = chapter.title,
            offset = same and read.offset or 0,
        }, done)
    end)
end

--- 书库里已有的元数据。
function Source:getDetailAsync(identity, cb)
    return SourceBase.defer(cb, identity.book or require("book.books_db").get(self.id, identity.stable_id))
end

--- 强制拉目录并写回；失败由调用方继续用旧缓存。轻阅读按书源取，先从书架行查 origin。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchTocAsync(self, identity, cb)
    local cancelled, job = false, nil
    local function fetch(origin)
        job = Client.chaptersAsync(identity.stable_id, origin, function(rows, err)
            if cancelled then return end
            if not rows then cb(nil, err); return end
            local toc = Mapper.toc(rows, origin)
            if #toc == 0 then cb(nil, _("阅读目录为空")); return end
            if not Toc.put(self.id, identity.stable_id, toc) then cb(nil, _("章节目录保存失败")); return end
            cb(toc)
        end)
    end
    if Client.mode() ~= "qread" then
        fetch(nil)
    else
        job = Client.shelfAsync(function(rows, err)
            if cancelled then return end
            local row = rows and findRow(rows, identity.stable_id)
            if not row then cb(nil, err or _("这本书不在阅读书架上")); return end
            fetch(row.origin)
        end)
    end
    return { cancel = function()
        cancelled = true
        job.cancel()
    end }
end

---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@param force boolean|nil 真=跳过缓存强制拉
---@return { cancel: fun() }
function Source:loadTocAsync(identity, cb, force)
    if not force then
        local cached = Toc.read(self.id, identity.stable_id)
        if cached and #cached > 0 then
            return SourceBase.defer(cb, cached)
        end
    end
    return fetchTocAsync(self, identity, cb)
end

Source.refreshTocAsync = fetchTocAsync

---@return ChapterFetchContent
-- 本地 EPUB（reader3 的 loc_book）章节：/getBookContent 返回的是章节资源路径
-- （形如 /book-assets/.../Text/xxx.xhtml），不是正文。下面把它当资源抓下来转成 HTML。
local function isAssetPath(s)
    if type(s) ~= "string" or #s == 0 or #s > 4096 then return false end
    if s:find("<", 1, true) then return false end
    return s:match("^/book%-assets/") ~= nil
        or s:match("%.xhtml$") ~= nil
        or s:match("%.html$") ~= nil
end

local function serverRoot()
    local base = Client.base()
    if not base then return nil end
    return (base:gsub("/reader3$", ""):gsub("/api/%d+$", ""))
end

local function encodePath(p)
    return (p:gsub("[^/]+", function(seg) return Text.urlEncode(seg) end))
end

local function dirOf(p)
    return (p:gsub("/[^/]*$", ""))
end

-- 相对地址（../Images/a.jpg）解析为服务器根相对路径（/book-assets/...）
local function resolvePath(base, rel)
    if rel:match("^%a[%w+.-]*://") or rel:match("^//") then return rel end
    if rel:sub(1, 1) == "/" then return rel end
    local segs = {}
    local joined = base .. "/" .. rel
    for seg in joined:gmatch("[^/]+") do
        if seg == ".." then
            if #segs > 0 then table.remove(segs) end
        elseif seg ~= "." then
            segs[#segs + 1] = seg
        end
    end
    return "/" .. table.concat(segs, "/")
end

-- 去掉标签后是否还有可见文字（判断"空章节"用，不能只看有没有 <p>）
local function hasVisibleText(html)
    local text = html:gsub("<[^>]*>", "")
    text = text:gsub("&nbsp;", ""):gsub("&amp;", ""):gsub("%s+", "")
    return #text > 0
end

local function assetToHtml(path, body, chapter)
    local inner = body:match("<body[^>]*>(.-)</body>") or body
    inner = inner:gsub("<script[^>]*>.-</script>", "")
    inner = inner:gsub("<style[^>]*>.-</style>", "")
    inner = inner:gsub("<%?xml.-%?>", "")

    -- 部分 EPUB 用内联 SVG 放图：<svg><image xlink:href="cover.jpeg"/></svg>。
    -- crengine 对内联 SVG 支持有限，这里转成普通 <img>，好走下面的图片本地化。
    local function svgToImg(block)
        local href = block:match('xlink:href%s*=%s*"([^"]*)"')
            or block:match("xlink:href%s*=%s*'([^']*)'")
            or block:match('href%s*=%s*"([^"]*)"')
            or block:match("href%s*=%s*'([^']*)'")
        if not href then return "" end
        return '<img src="' .. href .. '"/>'
    end
    inner = inner:gsub("<svg[^>]*>.-</svg>", svgToImg)
    inner = inner:gsub("<image%s[^>]-/>", svgToImg)

    local base_dir = dirOf(path)
    local function fix(src)
        local resolved = resolvePath(base_dir, src)
        if resolved:match("^/") then
            return Client.imageUrl(encodePath(resolved))
        end
        return resolved
    end
    inner = inner:gsub('(src%s*=%s*")([^"]*)(")', function(a, s2, c) return a .. fix(s2) .. c end)
    inner = inner:gsub("(src%s*=%s*')([^']*)(')", function(a, s2, c) return a .. fix(s2) .. c end)
    return "<h1>" .. Text.xmlEscape(chapter.title) .. "</h1>\n" .. inner, inner
end

local function contentFetcher()
    return function(identity, chapter, done)
        return Client.contentAsync(identity.stable_id, tonumber(chapter.uid), chapter.origin, function(text, err)
            if not text then done(nil, err); return end
            if isAssetPath(text) then
                local url
                if text:match("^https?://") then
                    url = text
                else
                    local root = serverRoot()
                    if not root then done(nil, _("未配置服务器地址")); return end
                    url = root .. encodePath(text)
                end
                return Request.get(url, { timeout = 20 }, function(body, ferr)
                    if type(body) ~= "string" or body == "" then
                        done(nil, ferr or _("章节资源为空")); return
                    end
                    local html, inner = assetToHtml(text, body, chapter)
                    -- 有的章节只有 <div> 和文字（如"总目录"），没有 <p>；
                    -- 有的封面是 SVG 图。都不能按"没有 <p>"判成空章节。
                    if not html:find("<img", 1, true) and not hasVisibleText(inner) then
                        done(nil, _("阅读章节内容为空")); return
                    end
                    -- crengine 不会自己拉网络图片：把图片下载到章节同目录的 images/
                    -- 再把 src 改写成相对路径，否则正文能出、图全是空白。
                    local hpath = Paths.chapterPath(identity.stable_id, tonumber(chapter.uid),
                                                    identity.source_id or "legado")
                    local images_dir = (hpath or ""):gsub("/[^/]+$", "") .. "/images"
                    return Assets.localizeAsync(html, images_dir, function(url2, on_done)
                        return Request.get(url2, { timeout = 45 }, function(raw)
                            on_done(type(raw) == "string" and raw ~= "" and raw or nil)
                        end)
                    end, function(final_html)
                        done({ title = chapter.title, html = final_html })
                    end)
                end)
            end
            local html = Mapper.chapterHtml(chapter.title, text, Client.imageUrl)
            -- 只有 <h1> 没有段落 = 服务器给的是空白正文，不能当成功落盘缓存。
            if not html:find("<p", 1, true) then done(nil, _("阅读章节内容为空")); return end
            done({ title = chapter.title, html = html })
        end)
    end
end

function Source:openBookAsync(identity, opts, cb)
    local Chapter = require("source.chapter")
    local open = opts and opts.chapter_idx and Chapter.openAsync or Chapter.openWithUi
    return open(self, identity, identity.book, opts, {
        loadToc = function(ref, done) return self:loadTocAsync(ref, done) end,
        fetchContent = contentFetcher(),
    }, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, {
        fetchContent = contentFetcher(),
    }, cb)
end

function Source:cacheAllChaptersAsync(identity, on_progress, cb, range)
    return require("source.chapter").cacheAllAsync(self, identity, contentFetcher(), on_progress, cb, 0, range)
end

return Legado
