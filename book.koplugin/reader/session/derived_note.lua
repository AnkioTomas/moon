--[[--
衍生版（双语版、排版版）与原书之间的划线收敛。

notes 表只存原书坐标：远端同步只认原书。衍生版和原书结构不同，xpointer 不通用，
所以衍生版自己的划线留在它的 sidecar 里，两边靠文字搜索互相定位：
- 读衍生版时（`project`）：notes 表里的原书划线在衍生版里搜出位置画上；
- 读原书时（`collect`）：各衍生版 sidecar 里新划的线在原书里搜出位置，写进原书，
  再由注解快照照常落库、推远端。只有 CREngine 原书能搜出 xpointer，PDF/DjVu 原书不收。

衍生版的约定：文件同目录有 `meta.json` = `{ origin, file }` 且 file 就是它自己；
都放在书的工作目录的一级子目录里（features/translate、features/reflow 各自生成）。

同一条划线在两边共用 KOReader 的 `datetime`。衍生版 sidecar 的 `book_note_linked`
记下已经两边对上的 datetime（true），以及在原书里搜不到的（false，划在译文上之类，
只留在衍生版、不再重搜）。它是三方合并的基线：
- 记为 true、本侧还在、对侧没了：对侧删了，本侧跟着删；
- 两边都在：`datetime_updated` 新的一方覆盖笔记、颜色、样式；
- 未记录、对侧没有：对侧的新划线，搜出位置加到本侧。
只有书签（没有 drawer）不跨版本。逐条搜索走 nextTick，不卡翻页。

衍生版文件整个重建（重新排版）时 sidecar 跟着清空，记为 false 的划线原书里没有，清了就没了：
`purge` 先把它们暂存到新 sidecar 的 `book_note_orphans`，下次打开衍生版时按文字重新落位（仍记 false）。

@module koplugin.book.reader.session.derived_note
--]]

local JSON = require("json")
local NoteDB = require("book.note_db")
local Normalize = require("book.note.normalize")

local DerivedNote = {}

local LINKED = "book_note_linked"
local ORPHANS = "book_note_orphans"
--- 搜索串取划线首尾各这么多个字：太短重复多，太长容易跨过排版版合并掉的断行。
local EDGE_CHARS = 16
local MAX_HITS = 200
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

--- 衍生版目录的 meta.json；没有或解不出来返回 nil。
---@param dir string
---@return { origin: string, file: string }|nil
function DerivedNote.readMeta(dir)
    local f = io.open(dir .. "/meta.json", "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    -- 每次存注解都会看文档同目录：用户书库里别的工具写的 meta.json 不能把存注解弄崩。
    local ok, meta = pcall(JSON.decode, data)
    return ok and type(meta) == "table" and meta or nil
end

--- 衍生版对应的原书路径；不是衍生版返回 nil。
---@param file string
---@return string|nil
function DerivedNote.originOf(file)
    local meta = DerivedNote.readMeta(file:match("^(.*)/[^/]+$") or ".")
    return meta and meta.file == file and meta.origin or nil
end

--- 书的工作目录里由 origin 生成、文件还在的衍生版路径。
---@param identity BookIdentity
---@param origin string
---@return string[]
local function derivedFiles(identity, origin)
    local lfs = require("libs/libkoreader-lfs")
    local root = require("utils.paths").bookWorkDir(identity.stable_id, identity.source_id)
    local files = {}
    if lfs.attributes(root, "mode") ~= "directory" then return files end
    for name in lfs.dir(root) do
        local meta = name ~= "." and name ~= ".." and DerivedNote.readMeta(root .. "/" .. name)
        if meta and meta.origin == origin and lfs.attributes(meta.file, "mode") == "file" then
            files[#files + 1] = meta.file
        end
    end
    return files
end

--- 划线文字首行开头 / 末行结尾的至多 EDGE_CHARS 个字。
---@param text string
---@param tail boolean
---@return string
local function edge(text, tail)
    local line = tail and text:match("([^\n]*)$") or text:match("^([^\n]*)")
    local chars = {}
    for char in line:gmatch(UTF8_CHAR) do chars[#chars + 1] = char end
    if tail then
        return table.concat(chars, "", math.max(1, #chars - EDGE_CHARS + 1))
    end
    return table.concat(chars, "", 1, math.min(#chars, EDGE_CHARS))
end

--- 在 CREngine 文档里搜出划线位置：开头取离全书比例最近的命中（比例未知取第一个），结尾取其后最近的命中。
---@param document table CreDocument
---@param text string
---@param fraction number|nil 划线在全书的大致位置 0..1；nil = 不知道
---@return string|nil pos0
---@return string|nil pos1
function DerivedNote.locate(document, text, fraction)
    text = require("utils.text").trim(text)
    if text == "" then return nil end
    local head, tail = edge(text, false), edge(text, true)
    local pages = document:getPageCount()
    local start, best
    for _idx, hit in ipairs(document:findAllText(head, false, 0, MAX_HITS) or {}) do
        local distance = fraction and math.abs(document:getPageFromXPointer(hit.start) / pages - fraction) or 0
        if not best or distance < best then start, best = hit, distance end
    end
    if not start then return nil end
    if head == text then return start.start, start["end"] end
    local stop
    for _idx, hit in ipairs(document:findAllText(tail, false, 0, MAX_HITS) or {}) do
        if document:compareXPointers(start.start, hit["end"]) == 1
                and (not stop or document:compareXPointers(hit["end"], stop) == 1) then
            stop = hit["end"]
        end
    end
    if stop then return start.start, stop end
end

---@param item table
---@param pages integer 划线所在文档的总页数（条目的 total_pages 缺失或为 0 时用；0 = 不知道）
---@return number|nil
local function fractionOf(item, pages)
    local total = item.total_pages
    if not total or total <= 0 then total = pages end
    if not item.pageno or total <= 0 then return nil end
    return item.pageno / total
end

---@param items table[]
---@return table<string, table>
local function byDatetime(items)
    local map = {}
    for _idx, item in ipairs(items) do
        if item.datetime then map[item.datetime] = item end
    end
    return map
end

--- 对侧更新过的笔记、颜色、样式盖到本侧。
---@param mine table
---@param theirs table
---@return boolean changed
local function adopt(mine, theirs)
    if (theirs.datetime_updated or "") <= (mine.datetime_updated or "") then return false end
    mine.note, mine.color, mine.drawer = theirs.note, theirs.color, theirs.drawer
    mine.datetime_updated = theirs.datetime_updated
    return true
end

--- 删掉对侧已删的划线（基线记为 true、对侧没了），并把对侧的修改合过来。
--- 两边都有却没记基线的（逐条补画中途关书，基线没来得及存）补记为 true，否则日后一侧删掉会被另一侧当新划线加回来。
---@param annotations table[] 本侧阅读器注解（就地改）
---@param linked table<string, boolean>
---@param theirs table<string, table>
---@return boolean changed 本侧注解有变
---@return boolean relinked 补记了基线
local function reconcile(annotations, linked, theirs)
    local changed, relinked = false, false
    for index = #annotations, 1, -1 do
        local item = annotations[index]
        local other = item.datetime and theirs[item.datetime]
        if linked[item.datetime] and not other then
            table.remove(annotations, index)
            changed = true
        elseif other then
            if not linked[item.datetime] then
                linked[item.datetime] = true
                relinked = true
            end
            changed = adopt(item, other) or changed
        end
    end
    for datetime, flag in pairs(linked) do
        if flag and not theirs[datetime] then linked[datetime] = nil end
    end
    return changed, relinked
end

--- 对侧新划线逐条搜位置加进本侧，每条一个 tick；文档换掉就停。
---@param ui table ReaderUI
---@param pending table[] 对侧条目
---@param pages integer 对侧文档总页数
---@param linked table<string, boolean>
---@param hit boolean 搜到的基线记什么（原书条目 true；衍生版自己的旧划线仍是 false）
---@param miss boolean|nil 搜不到的记什么（只有衍生版条目要记 false）
---@param done fun()
local function place(ui, pending, pages, linked, hit, miss, done)
    local UIManager = require("ui/uimanager")
    local document = ui.document
    local index = 0
    local function step()
        if ui.document ~= document then return end
        index = index + 1
        local item = pending[index]
        if not item then return done() end
        local mine = byDatetime(ui.annotation.annotations)
        if not mine[item.datetime] then
            local pos0, pos1 = DerivedNote.locate(document, item.text, fractionOf(item, pages))
            if pos0 then
                local chapter = ui.toc and ui.toc:getTocTitleByPage(pos0)
                ui.annotation:addItem({
                    page = pos0, pos0 = pos0, pos1 = pos1,
                    text = item.text, note = item.note, color = item.color, drawer = item.drawer,
                    datetime = item.datetime, datetime_updated = item.datetime_updated,
                    chapter = chapter ~= "" and chapter or nil,
                })
                linked[item.datetime] = hit
            elseif miss ~= nil then
                linked[item.datetime] = miss
            end
        end
        UIManager:nextTick(require("ui.guard").wrap("derived note", step))
    end
    UIManager:nextTick(require("ui.guard").wrap("derived note", step))
end

--- 对侧还没对上的新划线：有 drawer、有文字、基线里没有、本侧也没有。
---@param items table[]
---@param linked table<string, boolean>
---@param mine table<string, table>
---@return table[]
local function newcomers(items, linked, mine)
    local pending = {}
    for _idx, item in ipairs(items) do
        if item.drawer and item.datetime and item.text and linked[item.datetime] == nil
                and not mine[item.datetime] then
            pending[#pending + 1] = item
        end
    end
    return pending
end

---@param ui table
local function redraw(ui)
    ui.annotation:updateAnnotations(true)
    if ui.view then require("ui/uimanager"):setDirty(ui.view.dialog or "all", "partial") end
end

--- 读衍生版：把 notes 表里的原书划线画进来，原书删改的跟着删改。
---@param ui table ReaderUI，正在读衍生版
---@param identity BookIdentity
function DerivedNote.project(ui, identity)
    local row = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
    local items = Normalize.decode(row and row.payload) or {}
    -- 先挂回设置：逐条补画中途关书时，已补上的基线随 sidecar 一起落盘。
    local linked = ui.doc_settings:readSetting(LINKED) or {}
    ui.doc_settings:saveSetting(LINKED, linked)
    local annotations = ui.annotation.annotations
    local changed = reconcile(annotations, linked, byDatetime(items))
    local pending = newcomers(items, linked, byDatetime(annotations))
    -- 落位完才删：中途关书下次接着放，已放上的按 datetime 跳过。
    local orphans = ui.doc_settings:readSetting(ORPHANS)
    if changed then redraw(ui) end
    if #pending == 0 and not orphans then return end
    place(ui, pending, 0, linked, true, nil, function()
        if not orphans then return redraw(ui) end
        place(ui, orphans, 0, linked, false, nil, function()
            ui.doc_settings:delSetting(ORPHANS)
            redraw(ui)
        end)
    end)
end

--- 衍生版文件要整个重建、sidecar 随之清空：只在衍生版里的划线暂存进新 sidecar，等下次打开重新落位。
---@param file string 衍生版路径
function DerivedNote.purge(file)
    local DocSettings = require("docsettings")
    local old = DocSettings:open(file)
    local linked = old:readSetting(LINKED) or {}
    local pages = old:readSetting("doc_pages")
    -- 上次重建后还没打开过的，也一并带着。
    local orphans = old:readSetting(ORPHANS) or {}
    for _idx, item in ipairs(old:readSetting("annotations") or {}) do
        if item.drawer and item.datetime and linked[item.datetime] == false then
            item.total_pages = item.total_pages or pages
            orphans[#orphans + 1] = item
        end
    end
    old:purge()
    if #orphans == 0 then return end
    local fresh = DocSettings:open(file)
    fresh:saveSetting(ORPHANS, orphans)
    fresh:flush()
end

--- 读原书：把各衍生版里新划、改过、删掉的线收进原书，再存快照落库。
---@param ui table ReaderUI，正在读原书
---@param identity BookIdentity
function DerivedNote.collect(ui, identity)
    if not ui.rolling then return end
    local lfs = require("libs/libkoreader-lfs")
    for _idx, file in ipairs(derivedFiles(identity, ui.document.file)) do
        local settings = require("docsettings"):open(file)
        local built = lfs.attributes(file, "modification")
        local items = settings:readSetting("annotations") or {}
        local linked = settings:readSetting(LINKED) or {}
        local annotations = ui.annotation.annotations
        local changed, relinked = reconcile(annotations, linked, byDatetime(items))
        local pending = newcomers(items, linked, byDatetime(annotations))
        if relinked and not changed and #pending == 0 then
            settings:saveSetting(LINKED, linked)
            settings:flush()
        end
        local function finish()
            if changed or #pending > 0 then redraw(ui) end
            require("reader.session.note").save(ui, identity, function(ok)
                -- 逐条收线期间衍生版被重建（重新排版）：手里这份 sidecar 已过时，写回会盖掉新版的。
                if not ok or lfs.attributes(file, "modification") ~= built then return end
                settings:saveSetting(LINKED, linked)
                settings:flush()
            end)
        end
        if #pending == 0 then
            if changed then finish() end
        else
            place(ui, pending, settings:readSetting("doc_pages") or 0, linked, true, false, finish)
        end
    end
end

return DerivedNote
