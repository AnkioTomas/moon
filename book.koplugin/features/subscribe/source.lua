--[[--
订阅在阅读器里的书源：一个阅读范围是一本按章书（订阅页当前的筛选条件：源 / 分组 / 未读·全部·收藏 / 搜索词，
见 SubDB.scope；单个源 + 全部 + 无搜索词的 stable_id 仍是订阅 id），一篇文章是一章，
走 source.chapter 的落盘 / 快开与月读阅读会话（顶栏、侧栏目录、面板、字体排版），上一章 / 下一章就是相邻文章。

不进源清单（main 用 Registry.registerHidden 登记），书库、书架同步、选择器都看不到。
ephemeral：没有云端，阅读会话不存进度、不记统计（reader.session 入口按此跳过）；打开哪篇由订阅页指定章号。
目录 = 该范围在订阅页里的文章流（新到旧），章号随刷新 / 已读错位：目录变了按 uid 把章节文件、边车与注解挪到新章号（见 remapChapters）；
带注解的文章即使退出了范围（读过的不再算未读）也留在目录里，划线不丢。
uid：单源书是 guid，其余范围是「订阅 id:guid」。

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

--- 订阅页打开文章用的书：id 见 SubDB.scope，书名是范围名。
---@param id string
---@param title string
---@return Book
function M.book(id, title)
    return { source_id = M.ID, stable_id = id, title = title }
end

function Source:configured()
    return true
end

--- 已缓存文章里的二、三级标题（章内小节）；没缓存 / 旧缓存没有编号的文章没有小节。
---@param feed_id integer
---@param guid string
---@return BookChapterAnchor[]|nil
local function anchorsOf(feed_id, guid)
    local f = io.open(require("features.subscribe").dir(feed_id) .. "/articles/" .. require("ffi/sha2").md5(guid) .. ".html", "rb")
    if not f then return nil end
    local html = f:read("*a")
    f:close()
    local anchors = require("features.subscribe.typography").headings(html)
    return #anchors > 0 and anchors or nil
end

--- 章节 uid 拆成（订阅 id, guid）。
---@param identity BookIdentity
---@param uid string
---@return integer|nil feed_id
---@return string|nil guid
local function splitUid(identity, uid)
    if tostring(identity.stable_id):match("^%d+$") then return tonumber(identity.stable_id), uid end
    local feed_id, guid = uid:match("^(%d+):(.*)$")
    return tonumber(feed_id), guid
end

--- 这本书的目录：范围内的文章流；带注解的旧章（范围外了）按时间并回去。
---@param identity { stable_id: string }
---@return BookChapter[]
function M.toc(identity)
    local sid = tostring(identity.stable_id)
    local spec = SubDB.scopeOf(sid)
    if not spec then return {} end
    local single = sid:match("^%d+$")
    local list = SubDB.stream(spec, 1, -1)
    local have = {}
    for _idx, item in ipairs(list) do have[item.feed_id .. ":" .. item.guid] = true end
    local old = not single and require("source.toc").read(M.ID, sid, true)
    if old then
        local added
        for _idx, note in ipairs(require("book.note_db").all(M.ID, sid)) do
            local chapter = old[note.chapter_idx]
            if chapter then
                local feed_id, guid = splitUid(identity, chapter.uid)
                local item = feed_id and not have[feed_id .. ":" .. guid] and SubDB.item(feed_id, guid)
                if item then
                    have[feed_id .. ":" .. guid] = true
                    list[#list + 1] = item
                    added = true
                end
            end
        end
        if added then
            local pos = {}
            for i, item in ipairs(list) do pos[item] = i end
            table.sort(list, function(a, b)
                if a.time ~= b.time then return a.time > b.time end
                return pos[a] < pos[b]
            end)
        end
    end
    local toc = {}
    for i, item in ipairs(list) do
        toc[i] = { idx = i, uid = single and item.guid or (item.feed_id .. ":" .. item.guid),
            title = item.title ~= "" and item.title or _("无标题"), link = item.link,
            anchors = anchorsOf(item.feed_id, item.guid) }
    end
    return toc
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
    local toc = M.toc(identity)
    -- 旧目录是章节文件 / 注解现行章号的基线，过了 TTL 也得用：丢了基线就不挪，章号错位后划线串到别的文章上。
    local old = Toc.read(M.ID, identity.stable_id, true)
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
    elseif #toc > 0 then
        -- 目录没变，但文章缓存后多了小节：只更新目录缓存，不用挪章号。
        for i = 1, #toc do
            if #(old[i].anchors or {}) ~= #(toc[i].anchors or {}) then
                Toc.put(M.ID, identity.stable_id, toc)
                break
            end
        end
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
    local feed_id, guid = splitUid(identity, chapter.uid)
    local feed = feed_id and SubDB.feed(feed_id)
    if not feed then return SourceBase.defer(cb, nil, _("订阅已删除")) end
    local Subscribe = require("features.subscribe")
    return Subscribe.content(feed, { guid = guid, title = chapter.title, link = chapter.link or "" },
        function(html, err)
            if not html then return cb(nil, err) end
            -- 这篇刚缓存：小节写进目录缓存与调用方手里的目录项，打开目录马上就有。
            local anchors = require("features.subscribe.typography").headings(html)
            local toc = require("source.toc").read(M.ID, identity.stable_id, true)
            local entry = toc and toc[chapter.idx]
            local changed = entry and entry.uid == chapter.uid and #(entry.anchors or {}) ~= #anchors
            chapter.anchors = #anchors > 0 and anchors or nil
            if changed then
                entry.anchors = chapter.anchors
                require("source.toc").put(M.ID, identity.stable_id, toc)
            end
            -- 范围书（未读 / 收藏等）的章节文件不在订阅目录里，相对路径 images/ 要指回订阅目录。
            if identity.stable_id ~= tostring(feed_id) then
                local dir = Subscribe.dir(feed_id):match("[^/]+$")
                html = html:gsub('(<img[^>]-src=")images/', "%1../" .. dir .. "/images/")
            end
            cb({ document = require("features.subscribe.typography").document(feed.title, html) })
        end)
end

local OPS = {
    loadToc = function(ref, done) return Source.loadTocAsync(nil, ref, done) end,
    fetchContent = fetchContent,
    volatile = true,
}

--- 阅读器「重新下载本章」：章节文件之外，文章缓存也要作废，否则重下的还是旧正文。
---@param identity BookIdentity
---@param chapter BookChapter
function Source:dropChapterCache(identity, chapter)
    local feed_id, guid = splitUid(identity, chapter.uid)
    if feed_id and guid then os.remove(require("features.subscribe").articlePath(feed_id, guid)) end
end

---@param identity BookIdentity
---@param opts table|nil { chapter_idx }
---@param cb fun(path: string|nil, err: string|nil)
function Source:openBookAsync(identity, opts, cb)
    -- 本地快开不读目录：先按订阅库同步一次（同步完成，回调延后），顺序变了章节文件与划线先挪到新章号，
    -- 否则会按旧章号打开错位的文章。
    -- 阅读中切章不能再挪章号：调用方手里的章号是现行目录的，挪了就会开成别的文章（含「重新下载本章」）。
    Source.loadTocAsync(self, identity, function() end, not isOpen(identity))
    return require("source.chapter").openWithUi(self, identity, identity.book, opts or {}, OPS, cb)
end

function Source:prefetchChaptersAsync(identity, toc, from_idx, count, cb)
    return require("source.chapter").prefetchAsync(identity, identity.book, toc, from_idx, count, OPS, cb)
end

--- 翻到哪篇哪篇算已读。
function Source:onEvent(event, payload)
    if event ~= "chapter_changed" then return end
    local identity = payload and payload.identity
    ---@cast identity BookIdentity|nil
    local idx = identity and tonumber(identity.chapter_idx)
    local item = idx and (require("source.toc").read(M.ID, identity.stable_id, true) or {})[idx]
    if not item then return end
    local feed_id, guid = splitUid(identity, item.uid)
    if feed_id then SubDB.markRead(feed_id, guid, os.time()) end
end

return M
