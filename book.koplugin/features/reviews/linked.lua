--[[--
关联书段评：非微信读书的本地书（排版引擎能打开的格式：EPUB、AZW3、TXT、FB2、HTML…）关联一本微信读书书目后，借用它的段评。

关联存在 KOReader 书籍 sidecar（``doc_settings`` 的 ``book_reviews_wechat``），跟着文件走，不进库。

两个版本的分章常常对不上（本地「第三章」可能是微信「二」的开头），所以不认章号，按内容找：
当前页在全书的位置 ↔ 微信各章按字数累计的区间，取附近的章（两侧留 ``MARGIN``），
再加上当前目录标题对得上的章，最多 ``MAX_CHAPTERS`` 章。各章热点原句后台拉取（源侧有磁盘缓存），
拉到一章就重画一次。

找句（扫一页）：取前一页、本页、后一页的文字，去空白标点后找原句（跨页的句子也能找全），
只认窗口内唯一且与本页重叠的命中，再用命中的原文交排版引擎 ``findText`` 换成 xpointer。
xpointer 与排版无关，找到一次一直有效。扫一页在 Kindle 上要一两百毫秒，不能放在每次翻页里：
当前页没扫过才在绘制时扫，后 ``AHEAD`` 页在空闲 ``IDLE`` 秒后逐页预扫（``findText`` 从当前页往后搜两页，够得着）。
绘制只按页码筛出已定位的句子取屏幕框（页码随排版变，按排版指纹缓存）。

@module koplugin.book.features.reviews.linked
--]]

local PageMarks = require("reader.page_marks")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")

local Linked = {}

local KEY = "book_reviews_wechat"
--- 一页最多去对的微信章数（每章要发 1 + 热点数/40 个请求）。
local MAX_CHAPTERS = 6
--- 比例对齐的余量（全书比例）。
local MARGIN = 0.05
--- 太短的原句（去标点后不足 4 个汉字）到处都能撞上，不标。
local MIN_BYTES = 12
--- 某章拉取失败后多久再试（秒）：离线、网络抖动后能自己恢复，又不会每次翻页都打一次请求。
local RETRY = 60
--- 翻页后多久预扫（秒）：等翻页刷新完，不跟它抢。
local IDLE = 0.3
--- 往后预扫几页：findText 从当前页往后只搜两页高。
local AHEAD = 2

---@class ReviewLink
---@field book_id string 微信读书 bookId
---@field title string|nil
---@field author string|nil

--- 一条段评热点：identity 是该句所属的微信章身份（点按开段评用）。
---@class ReviewEntry
---@field identity BookIdentity
---@field spot WechatReviewHotspot

--- 屏上一处段评：句子与它在本屏的框。
---@class ReviewPlacement
---@field entry ReviewEntry
---@field boxes table[]

--- 关联书各微信章热点与在飞拉取，归阅读页（每个 ReaderUI 一份），跨书目复用。
---@class ReviewLinkCache
---@field hotspots table<string, WechatReviewHotspot[]> 「bookId\0章 uid」→ 热点
---@field loading table<string, { cancel: fun() }|integer> 在飞句柄，或失败时刻（秒）
---@field pos table<WechatReviewHotspot, string[]> 已定位的原句 { pos0, pos1 }
---@field pages table<WechatReviewHotspot, integer[]> 已定位原句的 { 起页, 止页 }（随排版失效）
---@field scanned table<integer, integer> 页 → 扫它时的热点数（热点多了要重扫；随排版失效）
---@field hash integer|nil pages / scanned 对应的排版指纹
---@field timer function|nil 待执行的下一页预扫
---@field job { job: { cancel: fun() }, page: integer }|nil 在飞的扫页子进程
---@field logged table<WechatReviewHotspot, boolean> 已记过「对不上」日志的原句

---@param ui table ReaderUI
---@return ReviewLink|nil
function Linked.get(ui)
    return ui.doc_settings and ui.doc_settings:readSetting(KEY)
end

---@param ui table ReaderUI
---@param link ReviewLink|nil nil = 解除关联
function Linked.set(ui, link)
    if link then
        ui.doc_settings:saveSetting(KEY, link)
    else
        ui.doc_settings:delSetting(KEY)
    end
end

--- 文档能按页取文字、找原句（排版引擎文档；PDF / 漫画没有这套接口）。
---@param document table
---@return boolean
function Linked.supported(document)
    return document.getPageXPointer ~= nil and document.findText ~= nil
end

---@return ReviewLinkCache
function Linked.newCache()
    return { hotspots = {}, loading = {}, pos = {}, pages = {}, scanned = {}, logged = {} }
end

--- 取消在飞拉取与预扫（已拉到的热点、已定位的原句保留）。
---@param cache ReviewLinkCache
function Linked.cancel(cache)
    if cache.timer then
        UIManager:unschedule(cache.timer)
        cache.timer = nil
    end
    if cache.job then
        cache.job.job:cancel()
        cache.job = nil
    end
    for key, job in pairs(cache.loading) do
        if type(job) == "table" then job.cancel() end
        cache.loading[key] = nil
    end
end

local CJK_PUNCT = {
    "　", "，", "。", "：", "；", "、", "！", "？", "“", "”", "‘", "’",
    "《", "》", "（", "）", "【", "】", "·", "—", "…", "「", "」", "『", "』", "～",
    "\226\128\139", "\239\187\191", -- 零宽空格、BOM：微信原句里常夹着
}
local PUNCT = {}
for _idx, p in ipairs(CJK_PUNCT) do PUNCT[p] = true end

--- 去空白标点：两个版本标点、空格常有出入，比文字本身。
--- 同时记下每个保留字在去后串里的字节位置 → 原文字节区间，命中后能截回原文。
---@param raw string
---@return string squashed
---@return table<integer, integer> from 去后串字符首字节 → 原文起点
---@return table<integer, integer> to 去后串字符末字节 → 原文终点
local function squash(raw)
    local parts, from, to, n = {}, {}, {}, 0
    for s, ch, e in raw:gmatch("()([%z\1-\127\194-\244][\128-\191]*)()") do
        if not (PUNCT[ch] or ch:match("^[%s%p]$")) then
            parts[#parts + 1] = ch
            from[n + 1] = s
            n = n + #ch
            to[n] = e - 1
        end
    end
    return table.concat(parts), from, to
end
Linked.squash = squash

local DIGITS = { ["零"] = 0, ["〇"] = 0, ["一"] = 1, ["二"] = 2, ["两"] = 2, ["三"] = 3, ["四"] = 4,
    ["五"] = 5, ["六"] = 6, ["七"] = 7, ["八"] = 8, ["九"] = 9 }
local UNITS = { ["十"] = 10, ["百"] = 100, ["千"] = 1000 }

--- 开头的中文数字 → 整数与余下部分（一百零五 = 105，十二 = 12，一九八四 = 1984）；不以中文数字开头返回 nil。
--- 这些字都是 3 字节 UTF-8，逐字比对，不能用字节字符类。
---@param s string
---@return integer|nil, string|nil
local function leadingNumber(s)
    local total, digit, pos = 0, nil, 1
    while true do
        local ch = s:sub(pos, pos + 2)
        if DIGITS[ch] then
            digit = (digit or 0) * 10 + DIGITS[ch]
        elseif UNITS[ch] then
            total = total + (digit or 1) * UNITS[ch]
            digit = nil
        else
            break
        end
        pos = pos + 3
    end
    if pos == 1 then return nil end
    return total + (digit or 0), s:sub(pos)
end

--- 归一化章名：去空白标点；开头的「第 N 章 / 回 / 节」与裸中文序号统一成阿拉伯数字
--- （本地「第一章」与微信「一」都成 1）。部、卷、篇保留，免得与章撞号。
---@param title string|nil
---@return string
local function norm(title)
    local s = squash(tostring(title or "")):gsub("^第", "")
    local num, rest = s:match("^(%d+)(.*)$")
    if not num then num, rest = leadingNumber(s) end
    if not num then return s end
    rest = rest:gsub("^[章回节]", "")
    return tostring(tonumber(num)) .. rest
end

--- 第 page 页所在的本地目录标题：每一层取页码不超过 page 的最后一项（章、节各一个）。
---@param toc table[] document:getToc()（带 page、depth）
---@param page integer
---@return string[]
function Linked.titlesAt(toc, page)
    local by_depth = {}
    for _idx, item in ipairs(toc) do
        if item.page <= page then by_depth[item.depth or 1] = item.title end
    end
    local out = {}
    for depth = 1, table.maxn(by_depth) do
        if by_depth[depth] then out[#out + 1] = by_depth[depth] end
    end
    return out
end

--- 章名或章内小节名归一化后满足 test 的微信章。
---@param chapters BookChapter[]
---@param test fun(name: string): boolean
---@return BookChapter[]
local function find(chapters, test)
    local out = {}
    for _idx, chapter in ipairs(chapters) do
        local hit = test(norm(chapter.title))
        for _anchor_idx, anchor in ipairs(chapter.anchors or {}) do
            hit = hit or test(norm(anchor.title))
        end
        if hit then out[#out + 1] = chapter end
    end
    return out
end

--- a 以 b 开头，且不是把数字从中间截开（1 不算 10 的前缀）。
---@param a string
---@param b string
---@return boolean
local function startsWith(a, b)
    return #a > #b and a:sub(1, #b) == b and not (b:match("%d$") and a:sub(#b + 1, #b + 1):match("%d"))
end

--- 本地标题 → 微信章：先比全等，没有再比前缀（一方是另一方开头），只认唯一命中。
---@param chapters BookChapter[] 微信目录
---@param titles string[]
---@return BookChapter[] 按标题顺序、去重
function Linked.byTitle(chapters, titles)
    local out, seen = {}, {}
    for _idx, title in ipairs(titles) do
        local want = norm(title)
        if want ~= "" then
            local hits = find(chapters, function(name) return name == want end)
            if #hits == 0 then
                hits = find(chapters, function(name)
                    return name ~= "" and (startsWith(name, want) or startsWith(want, name))
                end)
            end
            local chapter = #hits == 1 and hits[1] or nil
            if chapter and not seen[chapter] then
                seen[chapter] = true
                out[#out + 1] = chapter
            end
        end
    end
    return out
end

--- 全书位置 at（0..1）要去对的微信章：标题对上的在前，其余按字数比例落在 at ± MARGIN 内、离 at 近的在前。
---@param chapters BookChapter[] 微信目录（带 words）
---@param titles string[] 当前页的本地目录标题
---@param at number
---@param limit integer|nil 候选章上限，默认 MAX_CHAPTERS
---@return BookChapter[]
function Linked.candidates(chapters, titles, at, limit)
    local out, seen = {}, {}
    for _idx, chapter in ipairs(Linked.byTitle(chapters, titles)) do
        seen[chapter] = true
        out[#out + 1] = chapter
    end
    local total = 0
    for _idx, chapter in ipairs(chapters) do total = total + (chapter.words or 0) end
    if total > 0 then
        local near, acc = {}, 0
        for _idx, chapter in ipairs(chapters) do
            local s = acc / total
            acc = acc + (chapter.words or 0)
            local e = acc / total
            if e > at - MARGIN and s < at + MARGIN and not seen[chapter] then
                near[#near + 1] = { chapter = chapter, distance = math.abs((s + e) / 2 - at) }
            end
        end
        table.sort(near, function(x, y) return x.distance < y.distance end)
        for _idx, item in ipairs(near) do out[#out + 1] = item.chapter end
    end
    for i = #out, (limit or MAX_CHAPTERS) + 1, -1 do out[i] = nil end
    return out
end

--- 第 p 页的文字。最后一页没有「下一页起点」可截，只在它就是当前屏时取屏幕文字。
---@param ui table
---@param p integer
---@param page integer 当前页
---@param count integer 总页数
---@return string
local function pageText(ui, p, page, count)
    local document = ui.document
    if p < 1 or p > count then return "" end
    if p < count then
        return document:getTextFromXPointers(document:getPageXPointer(p), document:getPageXPointer(p + 1), true) or ""
    end
    if p ~= page then return "" end
    local width, height = PageMarks.screenSize(ui)
    local range = document:getTextFromPositions({ x = 0, y = 0 }, { x = width, y = height }, true)
    return range and range.text or ""
end

--- 扫第 p 页（在子进程里跑：要访问排版引擎，只读，结果经 JSON 回主进程）：
--- 前一页 + 本页 + 后一页文字里找未定位的原句，唯一且与本页重叠的交 findText 换成 xpointer。
---@param ui table ReaderUI
---@param entries ReviewEntry[]
---@param cache ReviewLinkCache
---@param p integer
---@return { found: table<integer, string[]>, why: table<integer, string> } 按热点序号
local function scan(ui, entries, cache, p)
    local document = ui.document
    local page, count = PageMarks.currentPage(ui), document:getPageCount()
    local prev, cur = pageText(ui, p - 1, page, count), pageText(ui, p, page, count)
    local raw = prev .. cur .. pageText(ui, p + 1, page, count)
    local cur0, cur1 = #prev + 1, #prev + #cur
    local text, from, to = squash(raw)
    local result = { found = {}, why = {} }
    for i, entry in ipairs(entries) do
        local spot = entry.spot
        local needle = squash(spot.text)
        local s, e = nil, nil
        if not cache.pos[spot] and #needle >= MIN_BYTES then s, e = text:find(needle, 1, true) end
        if s and from[s] <= cur1 and to[e] >= cur0 then
            if text:find(needle, s + 1, true) then
                result.why[i] = "ambiguous"
            else
                for _match_idx, match in ipairs(document:findText(raw:sub(from[s], to[e]), 0, 0, false, nil, false, 10) or {}) do
                    if document:getPageFromXPointer(match.start) <= p and document:getPageFromXPointer(match["end"]) >= p then
                        result.found[i] = { match.start, match["end"] }
                        break
                    end
                end
                if not result.found[i] then result.why[i] = "findText miss" end
            end
        elseif not s and not cache.pos[spot] and #needle >= MIN_BYTES then
            -- 开头对上、整句对不上：两版文字有出入（错字、增删），记下好比对。
            local hs = text:find(needle:sub(1, MIN_BYTES), 1, true)
            if hs and from[hs] <= cur1 then result.why[i] = "differs" end
        end
    end
    return result
end

--- 收下一页的扫描结果。排版已变（指纹对不上）的只收 xpointer（与排版无关），不记「已扫」。
---@param entries ReviewEntry[]
---@param cache ReviewLinkCache
---@param p integer
---@param hash integer
---@param result { found: table<integer, string[]>, why: table<integer, string> }|nil nil = 子进程失败
---@return integer 新定位的句子数
local function apply(entries, cache, p, hash, result)
    result = result or { found = {}, why = {} }
    local located = 0
    -- 子进程结果走 JSON，稀疏的热点序号回来是字符串键
    -- 序号稀疏时 rapidjson 编成数组，空位解成 json.null（函数值），只收 xpointer 对。
    for key, pos in pairs(result.found) do
        if type(pos) == "table" then
            cache.pos[entries[tonumber(key)].spot] = pos
            located = located + 1
        end
    end
    for key, why in pairs(result.why) do
        local spot = entries[tonumber(key)].spot
        if not cache.logged[spot] then
            cache.logged[spot] = true
            logger.info("book.reviews unmatched", why, "page", p, "quote", spot.text)
        end
    end
    -- 失败也记已扫：否则每次重绘都再开一个必败的子进程。
    if cache.hash == hash then cache.scanned[p] = #entries end
    return located
end

--- 起一个子进程扫第 p 页，同一时刻只有一个；扫完收下结果，有新定位就重画，再排后几页的预扫。
---@param ui table ReaderUI
---@param entries ReviewEntry[]
---@param cache ReviewLinkCache
---@param p integer
---@param page integer 当前页
---@param redraw fun()
local function startScan(ui, entries, cache, p, page, redraw)
    if cache.job then
        if cache.job.page == p then return end
        cache.job.job:cancel()
        cache.job = nil
    end
    local hash = cache.hash
    local function finish(result)
        cache.job = nil
        if not ui.document then return end
        if apply(entries, cache, p, hash, result) > 0 then redraw() end
        -- 翻走了就不接着排旧页的预扫，下次绘制会重排。
        if PageMarks.currentPage(ui) == page then Linked.scheduleScan(ui, entries, cache, page, redraw) end
    end
    local job = require("workers.job").run(function() return scan(ui, entries, cache, p) end, {
        name = "reviews.scan",
        kind = "light",
        timeout = 30,
        on_done = finish,
        on_failed = function(err)
            logger.warn("book.reviews scan failed", err)
            finish(nil)
        end,
    })
    if not job.settled then cache.job = { job = job, page = p } end
end

--- 空闲后逐页预扫当前页之后 AHEAD 页里没扫过的；视口变了（翻页、关书）就作废。
---@param ui table ReaderUI
---@param entries ReviewEntry[]
---@param cache ReviewLinkCache
---@param page integer 当前页
---@param redraw fun()
function Linked.scheduleScan(ui, entries, cache, page, redraw)
    if cache.timer then UIManager:unschedule(cache.timer) end
    cache.timer = nil
    local last = math.min(page + AHEAD, ui.document:getPageCount())
    local p = page + 1
    while p <= last and cache.scanned[p] == #entries do p = p + 1 end
    if p > last then return end
    local key = PageMarks.viewKey(ui, 0)
    cache.timer = require("ui.guard").wrap("reviews scan", function()
        cache.timer = nil
        if not key or PageMarks.viewKey(ui, 0) ~= key then return end
        startScan(ui, entries, cache, p, page, redraw)
    end)
    UIManager:scheduleIn(IDLE, cache.timer)
end

--- 当前屏的段评：当前页没扫过先后台扫（扫完重画），再按页码筛出已定位的句子取屏幕框；之后排后几页的预扫。
---@param ui table ReaderUI
---@param entries ReviewEntry[]
---@param cache ReviewLinkCache
---@param redraw fun() 新定位了句子，重画
---@return ReviewPlacement[]
function Linked.place(ui, entries, cache, redraw)
    local document = ui.document
    local hash = document:getDocumentRenderingHash()
    if cache.hash ~= hash then
        cache.hash, cache.pages, cache.scanned = hash, {}, {}
    end
    local page = PageMarks.currentPage(ui)
    if cache.scanned[page] ~= #entries then
        startScan(ui, entries, cache, page, page, redraw)
    end
    -- 双栏、滚动模式一屏最多跨两页。
    local width, height = PageMarks.screenSize(ui)
    local out = {}
    for _idx, entry in ipairs(entries) do
        local pos = cache.pos[entry.spot]
        local span = pos and cache.pages[entry.spot]
        if pos and not span then
            span = { document:getPageFromXPointer(pos[1]), document:getPageFromXPointer(pos[2]) }
            cache.pages[entry.spot] = span
        end
        if span and span[1] <= page + 1 and span[2] >= page then
            local boxes = {}
            for _box_idx, box in ipairs(document:getScreenBoxesFromPositions(pos[1], pos[2], true) or {}) do
                if PageMarks.intersects(box, width, height) then boxes[#boxes + 1] = box end
            end
            if #boxes > 0 then out[#out + 1] = { entry = entry, boxes = boxes } end
        end
    end
    if not cache.job then Linked.scheduleScan(ui, entries, cache, page, redraw) end
    return out
end

--- 当前页附近微信章的热点；还没拉的发起后台拉取（拉到后 redraw），失败的过 RETRY 秒再试。
---@param ui table
---@param source ParagraphReviewSource
---@param book_id string
---@param toc BookChapter[]
---@param cache ReviewLinkCache
---@param redraw fun()
---@return ReviewEntry[]
function Linked.entries(ui, source, book_id, toc, cache, redraw)
    local document = ui.document
    local page = PageMarks.currentPage(ui)
    local at = (page - 1) / document:getPageCount()
    local entries = {}
    for _idx, chapter in ipairs(Linked.candidates(toc, Linked.titlesAt(document:getToc() or {}, page), at)) do
        local identity = { source_id = source.id, stable_id = book_id, chapter_idx = chapter.idx, source = source }
        local key = book_id .. "\0" .. tostring(chapter.uid)
        local hotspots, loading = cache.hotspots[key], cache.loading[key]
        if hotspots then
            for _spot_idx, spot in ipairs(hotspots) do entries[#entries + 1] = { identity = identity, spot = spot } end
        elseif not loading or (type(loading) == "number" and os.time() - loading >= RETRY) then
            local done = false
            local job = source:paragraphHotspotsAsync(identity, function(fetched, err)
                done = true
                if not fetched then
                    logger.warn("book.reviews chapter failed", chapter.idx, err)
                    cache.loading[key] = os.time()
                    return
                end
                cache.loading[key] = nil
                cache.hotspots[key] = fetched
                logger.info("book.reviews chapter", chapter.idx, chapter.title, "hotspots", #fetched)
                redraw()
            end)
            if not done then cache.loading[key] = job end
        end
    end
    return entries
end

--- 关联的微信目录；旧格式目录没有章节字数，强制重拉一次。
---@param source ParagraphReviewSource
---@param book_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Linked.tocAsync(source, book_id, cb)
    local book = { source_id = source.id, stable_id = book_id }
    local job
    job = source:loadTocAsync(book, function(toc, err)
        if toc and not source:isTocCurrent(toc) then
            job = source:refreshTocAsync(book, cb)
            return
        end
        cb(toc, err)
    end)
    return { cancel = function()
        if job then job.cancel() end
    end }
end

--- 关联书的段评目标：键只认书目；fetch 拉微信目录，place 按当前页拉章、找句、取框。
---@param ui table ReaderUI
---@param cache ReviewLinkCache
---@param redraw fun() 某章热点到了，重画
---@return { key: string, fetch: fun(cb: fun(toc: BookChapter[]|nil, err: string|nil)): { cancel: fun() }, place: fun(toc: BookChapter[]): ReviewPlacement[] }|nil
function Linked.target(ui, cache, redraw)
    local link = Linked.get(ui)
    if not (link and Linked.supported(ui.document)) then return nil end
    local source = require("source.registry").resolve("wechat") --[[@as ParagraphReviewSource]]
    if not (source:configured() and source:paragraphReviewsEnabled()) then return nil end
    return {
        key = "link\0" .. link.book_id,
        fetch = function(cb) return Linked.tocAsync(source, link.book_id, cb) end,
        place = function(toc)
            return Linked.place(ui, Linked.entries(ui, source, link.book_id, toc, cache, redraw), cache, redraw)
        end,
    }
end

---@param identity BookIdentity
---@return string
local function linkKey(identity)
    return tostring(identity.source_id or "") .. "\0" .. tostring(identity.stable_id)
end

--- 章会话的关联：每章是一个独立文档，doc_settings 一章一份存不住，按书存进 settings/reviews.lua 的 chapter_links。
---@param identity BookIdentity
---@return ReviewLink|nil
function Linked.getFor(identity)
    if not (identity and identity.stable_id) then return nil end
    local links = require("utils.settings").get("features.reviews").chapter_links or {}
    return links[linkKey(identity)]
end

---@param identity BookIdentity
---@param link ReviewLink|nil nil = 解除关联
function Linked.setFor(identity, link)
    if not (identity and identity.stable_id) then return end
    local MoonSettings = require("utils.settings")
    local data = MoonSettings.get("features.reviews")
    data.chapter_links = data.chapter_links or {}
    data.chapter_links[linkKey(identity)] = link
    MoonSettings.save("features.reviews", data)
end

--- 本章在全书的位置比例（按 words 累计取章中点；目录没有字数时按章序号）与章名。
---@param chapters BookChapter[]|nil
---@param chapter_idx number|nil
---@return number at 0..1
---@return string|nil title
function Linked.anchorOf(chapters, chapter_idx)
    chapters = chapters or {}
    local total, acc, title, pos = 0, 0, nil, nil
    for i, chapter in ipairs(chapters) do
        total = total + (chapter.words or 0)
        if chapter.idx == chapter_idx then pos, title = i, chapter.title end
    end
    if not pos then return 0, nil end
    if total <= 0 then return (pos - 0.5) / #chapters, title end
    for i = 1, pos - 1 do acc = acc + (chapters[i].words or 0) end
    return (acc + (chapters[pos].words or 0) / 2) / total, title
end

--- 章会话借关联书目的段评：按本章位置与章名到关联书目录里挑章（最多 8 章），
--- 拉这些章的热点并记上归属章 ``spot.chapter_idx``（未定位，由调用方定位到本章 HTML）。
---@param source ParagraphReviewSource 微信读书源
---@param identity BookIdentity 本章身份（带 chapter_idx 与属主源）
---@param link ReviewLink
---@param cb fun(hotspots: WechatReviewHotspot[]|nil)
---@return { cancel: fun() }
function Linked.chapterHotspotsAsync(source, identity, link, cb)
    local cancelled, jobs = false, {}
    local function cancel()
        cancelled = true
        for _idx, job in ipairs(jobs) do if job.cancel then job.cancel() end end
    end
    local owner = identity.source or source
    local own = { source_id = identity.source_id, stable_id = identity.stable_id, source = owner }
    local own_job = owner:loadTocAsync(own, function(toc)
        if cancelled then return end
        local at, title = Linked.anchorOf(toc, tonumber(identity.chapter_idx))
        jobs[#jobs + 1] = Linked.tocAsync(source, link.book_id, function(remote)
            if cancelled then return end
            if not remote then cb(nil); return end
            -- 两本书分章对不上时多对几章（章名对上的排在最前）
            local chapters = Linked.candidates(remote, title and { title } or {}, at, 8)
            local collected, pending = {}, #chapters
            if pending == 0 then cb(collected); return end
            for _idx, chapter in ipairs(chapters) do
                jobs[#jobs + 1] = source:paragraphHotspotsAsync({
                    source_id = source.id, stable_id = link.book_id, chapter_idx = chapter.idx, source = source,
                }, function(hotspots)
                    if cancelled or pending <= 0 then return end
                    for _spot_idx, spot in ipairs(hotspots or {}) do
                        -- 段评归属章：翻段评要用这一章的身份，range 才有效
                        spot.chapter_idx = chapter.idx
                        collected[#collected + 1] = spot
                    end
                    pending = pending - 1
                    if pending == 0 then cb(collected) end
                end)
            end
        end)
    end)
    if own_job then jobs[#jobs + 1] = own_job end
    return { cancel = cancel }
end

return Linked
