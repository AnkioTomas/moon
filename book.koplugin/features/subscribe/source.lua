--[[--
订阅在阅读器里的书源：一个订阅是一本按章书（stable_id = 订阅 id），一篇文章是一章，
走 source.chapter 的落盘 / 快开与月读阅读会话（顶栏、侧栏目录、面板、字体排版），上一章 / 下一章就是相邻文章。

不进源清单（main 用 Registry.registerHidden 登记），书库、书架同步、选择器都看不到。
ephemeral：没有云端，阅读会话不存进度、不记统计（reader.session 入口按此跳过）；打开哪篇由订阅页指定章号。
目录 = 订阅页同序（新到旧），章号随刷新错位：目录变了按 guid 把章节文件、边车与注解挪到新章号（见 remapChapters）。

@module koplugin.book.features.subscribe.source
--]]

local SourceBase = require("source.base")
local SubDB = require("features.subscribe.db")
local Paths = require("utils.paths")
local logger = require("utils.log")
local _ = require("gettext")

local M = {}

M.ID = "subscribe"

---@return BookSourceMeta
function M.meta()
    return { id = M.ID, name = _("订阅"), type = "chapter" }
end

local Source = setmetatable({ ephemeral = true }, { __index = SourceBase })
Source.__index = Source

function M.new()
    local meta = M.meta()
    return setmetatable({ id = meta.id, name = meta.name, type = meta.type }, Source)
end

--- 订阅页打开文章用的书：书名是订阅名。
---@param feed table
---@return Book
function M.book(feed)
    return { source_id = M.ID, stable_id = tostring(feed.id), title = feed.title }
end

function Source:configured()
    return true
end

---@param identity BookIdentity
---@return table|nil
local function feedOf(identity)
    return SubDB.feed(tonumber(identity.stable_id))
end

--- 目录变了（刷新新增 / 淘汰旧条目）：按 guid 把旧章号挪到新章号，划线跟着文章走。
--- 章节文件、双语章与 KOReader 边车（<n>.html / <n>.bi-*.html / 对应 .sdr）改名，月读注解改章号；
--- 已淘汰文章的这些一并删掉。章节登记撤掉，开章时 Store.touch 按新路径重登。articles/、images/ 不动。
---@param identity BookIdentity
---@param old BookChapter[]
---@param toc BookChapter[]
local function remapChapters(identity, old, toc)
    local new_idx, map = {}, {}
    for i, item in ipairs(toc) do new_idx[item.uid] = i end
    for i, item in ipairs(old) do map[i] = new_idx[item.uid] end
    require("book.note_db").remapChapters(M.ID, identity.stable_id, map)
    local dir = Paths.bookWorkDir(identity.stable_id, M.ID)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local function drop(path)
        if lfs.attributes(path, "mode") == "directory" then
            require("ffi/util").purgeDir(path)
        else
            os.remove(path)
        end
    end
    local moves = {}
    for name in lfs.dir(dir) do
        local n, rest = name:match("^(%d+)(%..+)$")
        if name:sub(1, 4) == ".mv-" then
            drop(dir .. "/" .. name) -- 上次改名中途失败留下的临时名：章节缓存，删了重开会重建
        elseif n and (rest:match("^%.html$") or rest:match("^%.sdr$") or rest:match("^%.bi%-.+%.html$")
            or rest:match("^%.bi%-.+%.sdr$")) then
            moves[#moves + 1] = { name = name, to = map[tonumber(n)], rest = rest }
        end
    end
    -- 两段改名：先全部挪到临时名，再落到新章号，避免 2→3、3→4 互相覆盖。
    -- 改名失败的那份直接删（只是章节缓存），绝不留在旧章号上错位。
    for _idx, m in ipairs(moves) do
        local from = dir .. "/" .. m.name
        if not (m.to and os.rename(from, dir .. "/.mv-" .. m.name)) then
            if m.to then logger.warn("subscribe remap rename failed", from) end
            m.to = nil
            drop(from)
        end
    end
    for _idx, m in ipairs(moves) do
        if m.to then
            local tmp = dir .. "/.mv-" .. m.name
            if not os.rename(tmp, dir .. "/" .. m.to .. m.rest) then
                logger.warn("subscribe remap rename failed", tmp)
                drop(tmp)
            end
        end
    end
    require("book.chapters_db").deleteUnder(dir)
end

--- 这本订阅书是否正开在阅读器里。
---@param identity BookIdentity
---@return boolean
local function isOpen(identity)
    local snap = require("reader.session").current()
    local cur = snap and snap.identity
    return cur ~= nil and cur.source_id == M.ID and tostring(cur.stable_id) == tostring(identity.stable_id)
end

--- 目录同步。阅读中（这本书正开着）目录变了不重排章号：沿用旧目录，等下次打开（force）再挪，
--- 免得正在看的章节文件、边车被改名、上一章 / 下一章错位。
---@param identity BookIdentity
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@param force boolean|nil 打开书时为真：无论是否开着都同步
function Source:loadTocAsync(identity, cb, force)
    local Toc = require("source.toc")
    local items = SubDB.items(tonumber(identity.stable_id), 1, -1)
    local toc = {}
    for i, item in ipairs(items) do
        toc[i] = { idx = i, uid = item.guid, title = item.title ~= "" and item.title or _("无标题"), link = item.link }
    end
    local old = Toc.read(M.ID, identity.stable_id)
    local same = old and #old == #toc
    for i = 1, same and #toc or 0 do
        if old[i].uid ~= toc[i].uid then same = false break end
    end
    if not same and old and #old > 0 and not force and isOpen(identity) then
        return SourceBase.defer(cb, old)
    end
    if not same then
        if old then remapChapters(identity, old, toc) end
        if #toc > 0 then Toc.put(M.ID, identity.stable_id, toc) end
    end
    if #toc == 0 then return SourceBase.defer(cb, nil, _("订阅里还没有文章")) end
    return SourceBase.defer(cb, toc)
end

function Source:refreshTocAsync(identity, cb)
    return Source.loadTocAsync(self, identity, cb)
end

---@param identity BookIdentity
---@param chapter BookChapter
---@param cb fun(payload: ChapterContentPayload|nil, err: any)
local function fetchContent(identity, chapter, cb)
    local feed = feedOf(identity)
    if not feed then return SourceBase.defer(cb, nil, _("订阅已删除")) end
    local Subscribe = require("features.subscribe")
    return Subscribe.content(feed, { guid = chapter.uid, title = chapter.title, link = chapter.link or "" },
        function(html, err)
            if not html then return cb(nil, err) end
            cb({ document = require("features.subscribe.typography").document(feed.title, html) })
        end)
end

local OPS = {
    loadToc = function(ref, done) return Source.loadTocAsync(nil, ref, done) end,
    fetchContent = fetchContent,
}

---@param identity BookIdentity
---@param opts table|nil { chapter_idx }
---@param cb fun(path: string|nil, err: string|nil)
function Source:openBookAsync(identity, opts, cb)
    -- 本地快开不读目录：先按订阅库同步一次（同步完成，回调延后），顺序变了章节文件与划线先挪到新章号，
    -- 否则会按旧章号打开错位的文章。
    Source.loadTocAsync(self, identity, function() end, true)
    return require("source.chapter").openWithUi(self, identity, identity.book, opts or {}, OPS, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, OPS, cb)
end

--- 翻到哪篇哪篇算已读。
function Source:onEvent(event, payload)
    if event ~= "chapter_changed" then return end
    local identity = payload and payload.identity
    local idx = identity and tonumber(identity.chapter_idx)
    local item = idx and (require("source.toc").read(M.ID, identity.stable_id) or {})[idx]
    if item then SubDB.markRead(tonumber(identity.stable_id), item.uid) end
end

return M
