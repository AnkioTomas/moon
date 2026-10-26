--[[-- features.reviews.linked：本地书关联微信书目，按当前页位置选微信章、页内文字找原句、findText 取框。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local Linked = require("features.reviews.linked")

-- 去空白标点：比文字本身，并能截回原文。
local raw = "他说：“好， 走吧。”"
local text, from, to = Linked.squash(raw)
Assert.eq(text, "他说好走吧")
local s, e = text:find("好走", 1, true)
Assert.eq(raw:sub(from[s], to[e]), "好， 走", "命中截回原文（含中间标点空白）")
Assert.eq(Linked.squash("a\226\128\139b"), "ab", "零宽空格")
Assert.eq(Linked.squash(""), "")

-- 当前页的目录标题：每层取页码不超过当前页的最后一项。
local toc = {
    { title = "封面", page = 1, depth = 1 },
    { title = "第一章", page = 5, depth = 1 },
    { title = "一、少年", page = 6, depth = 2 },
    { title = "第二章", page = 9, depth = 1 },
}
local titles = Linked.titlesAt(toc, 7)
Assert.len(titles, 2)
Assert.eq(titles[1], "第一章")
Assert.eq(titles[2], "一、少年")
Assert.eq(Linked.titlesAt(toc, 10)[1], "第二章")
Assert.len(Linked.titlesAt({}, 3), 0)

-- 标题对齐：本地「第一章」= 微信「一」；全等优先于前缀；1 不是 10 的前缀；小节名指向所属章；歧义不认。
local chapters = {
    { idx = 1, uid = "10", title = "一", anchors = { { title = "少年" } }, words = 100 },
    { idx = 2, uid = "11", title = "第二章 归乡", words = 100 },
    { idx = 3, uid = "12", title = "附录 甲", words = 100 },
    { idx = 4, uid = "13", title = "附录 乙", words = 100 },
    { idx = 5, uid = "14", title = "十", words = 100 },
    { idx = 6, uid = "15", title = "第十一章", words = 100 },
}
local hit = Linked.byTitle(chapters, { "第一章", "一、少年" })
Assert.len(hit, 1, "章名与其小节都指向同一章，只取一次")
Assert.eq(hit[1].uid, "10")
Assert.eq(Linked.byTitle(chapters, { "第 二 章" })[1].uid, "11", "前缀命中")
Assert.eq(Linked.byTitle(chapters, { "第10章" })[1].uid, "14", "阿拉伯数字与中文数字同号")
Assert.eq(Linked.byTitle(chapters, { "11" })[1].uid, "15")
Assert.len(Linked.byTitle({ chapters[5] }, { "第1章" }), 0, "1 不是 10 的前缀")
Assert.len(Linked.byTitle(chapters, { "附录" }), 0, "前缀命中多章即歧义")
Assert.len(Linked.byTitle(chapters, { "后记", "" }), 0)

-- 候选：标题命中在前，其余按字数比例落在 at ± 0.05 内、离 at 近的在前；最多 6 章。
-- 6 章各 1/6：at = 0.42 → [0.37, 0.47) 只落在第 3 章（1/3..1/2）。
local cands = Linked.candidates(chapters, {}, 0.42)
Assert.len(cands, 1)
Assert.eq(cands[1].uid, "12")
cands = Linked.candidates(chapters, { "第一章" }, 0.42)
Assert.eq(cands[1].uid, "10", "标题命中排第一")
Assert.eq(cands[2].uid, "12")
-- 章界附近：两章都要，离 at 近的先。
cands = Linked.candidates(chapters, {}, 0.32)
Assert.len(cands, 2)
Assert.eq(cands[1].uid, "11")
Assert.eq(cands[2].uid, "12")
local many = {}
for i = 1, 1000 do many[i] = { idx = i, uid = tostring(i), title = "x" .. i, words = 10 } end
Assert.len(Linked.candidates(many, {}, 0.5), 6, "封顶")
Assert.len(Linked.candidates({ { idx = 1, uid = "1", title = "x" } }, {}, 0.5), 0, "无字数只看标题")

-- 放置：5 页文字；页码 = xpointer。findText 回命中原文所在页（where 登记），模拟视口附近的搜索。
local pages = {
    "开头无关的文字。",
    "第二页说他慢慢地走",
    "到了村口，看见那头老牛。这里重复重复重复重复。",
    "这里重复重复重复重复。还有很短的。第四页的一句话在这里。",
    "最后一页的文字在屏幕上。",
}
local where = { ["他慢慢地走\n到了村口"] = { 2, 3 }, ["看见那头老牛"] = { 3, 3 }, ["第四页的一句话在这里"] = { 4, 4 },
    ["最后一页的文字在屏幕上"] = { 5, 5 }, ["离屏的文字也是一句话呀"] = { 5, 5 } }
local found, box_calls, hash = {}, 0, 1
local document = {
    file = "/books/huozhe.epub",
    page = 3,
    getPageCount = function() return #pages end,
    getDocumentRenderingHash = function() return hash end,
    getPageXPointer = function(_self, p) return p <= #pages and tostring(p) or "" end,
    getTextFromXPointers = function(_self, a, b)
        Assert.eq(tonumber(b), tonumber(a) + 1)
        return pages[tonumber(a)]
    end,
    getTextFromPositions = function(self) return { text = pages[self.page] } end,
    findText = function(_self, pattern)
        found[#found + 1] = pattern
        return { { start = "s\0" .. pattern, ["end"] = "e\0" .. pattern } }
    end,
    getPageFromXPointer = function(_self, xp)
        local side, pattern = xp:match("^(%a)%z(.*)$")
        return where[pattern][side == "s" and 1 or 2]
    end,
    getScreenBoxesFromPositions = function(_self, pos0)
        box_calls = box_calls + 1
        if pos0:find("离屏", 1, true) then return { { x = 0, y = 900, w = 10, h = 10 } } end
        return { { x = 1, y = 2, w = 30, h = 20 } }
    end,
    getToc = function() return {} end,
}
pages[2] = "第二页说他慢慢地走\n"
local session = { identity = { source_id = "local", stable_id = "/books/huozhe.epub" } }
package.loaded["reader.session"] = { current = function() return session end }
local ui = {
    document = document,
    view = { dimen = { w = 600, h = 800 } },
    getCurrentPage = function() return document.page end,
}
local function entry(sentence) return { identity = { chapter_idx = 1 }, spot = { text = sentence, range = sentence } } end
local entries = {
    entry("他慢慢地走到了村口"), -- 跨第 2、3 页，标点换行不同
    entry("看见那头老牛"),
    entry("这里重复重复重复重复"), -- 窗口里出现两次：歧义
    entry("开头无关的文字"), -- 只在第 1 页：不在窗口内
    entry("很短"), -- 太短
    entry("不存在的句子啊啊"),
    entry("第四页的一句话在这里"), -- 在下一页：本页不标，空闲时预扫
}
local scan_redraws = 0
-- 子进程桩：同步跑 worker 再回调（真机 fork 后 JSON 回传）。
package.loaded["workers.job"] = { run = function(worker, opts)
    local ok, result = pcall(worker)
    -- 真机结果走 JSON：稀疏整数键回来是字符串键
    if ok then
        for _idx, field in ipairs({ "found", "why" }) do
            local wire = {}
            for i, v in pairs(result[field]) do wire[tostring(i)] = v end
            result[field] = wire
        end
        opts.on_done(result)
    else
        opts.on_failed(result)
    end
    return { settled = true, cancel = function() end }
end }
local function place(view, list, c) return Linked.place(view, list, c, function() scan_redraws = scan_redraws + 1 end) end
local cache = Linked.newCache()
local out = place(ui, entries, cache)
Assert.len(out, 2)
Assert.eq(out[1].entry, entries[1])
Assert.eq(found[1], "他慢慢地走\n到了村口", "截回原文交 findText")
Assert.len(found, 2)
Assert.eq(out[1].boxes[1].w, 30)
Assert.eq(out[2].entry, entries[2])
Assert.eq(scan_redraws, 1, "扫出新定位就重画")
Assert.not_nil(cache.timer, "排了下一页预扫")

-- 同页重画：不再找句，只按已定位的取框。
found = {}
Assert.len(place(ui, entries, cache), 2)
Assert.len(found, 0)

-- 空闲逐页预扫后两页：翻过去时直接有框。
Stubs.flush()
Assert.eq(found[1], "第四页的一句话在这里")
Assert.eq(cache.scanned[4], #entries)
Assert.eq(cache.scanned[5], #entries, "预扫到当前页后第 2 页")
Assert.is_nil(cache.timer, "扫完不再排")
document.page, found = 4, {}
out = place(ui, entries, cache)
Assert.len(found, 0, "预扫过的页翻过去不找句")
Assert.eq(out[#out].entry, entries[7])

-- 视口变了（翻走、关书）：预扫作废。
document.page = 3
cache.scanned[4] = nil
place(ui, entries, cache)
local pending = cache.timer
session = nil
pending()
Assert.is_nil(cache.scanned[4], "会话没了不扫")
session = { identity = { source_id = "local", stable_id = "/books/huozhe.epub" } }

-- 排版变了：页码重算、页面重扫，xpointer 沿用。
hash, found = 2, {}
local before = box_calls
Assert.len(place(ui, entries, cache), 3, "下一页已定位的句子也取框（双栏一屏两页），屏外的由屏幕相交裁掉")
Assert.len(found, 0, "已定位的不再 findText")
Assert.eq(box_calls, before + 3)
Assert.eq(cache.scanned[3], #entries)

-- 热点多了：本页重扫。
local more = { entries[1], entries[2], entry("看见那头老牛") }
place(ui, more, cache)
Assert.eq(cache.scanned[3], 3)

-- 原句在后一页（不与本页重叠）当前页不标。
document.page = 2
Assert.len(place(ui, { entry("看见那头老牛") }, Linked.newCache()), 0)

-- 最后一页：没有下一页起点，取屏幕文字；不排预扫。
document.page = 5
local last = Linked.newCache()
Assert.len(place(ui, { entry("最后一页的文字在屏幕上") }, last), 1)
Assert.is_nil(last.timer)

-- 框都在屏外：不出标记。
pages[5] = "离屏的文字也是一句话呀。"
Assert.len(place(ui, { entry("离屏的文字也是一句话呀") }, Linked.newCache()), 0)

-- 取消：撤掉待执行的预扫。
document.page = 3
local c4 = Linked.newCache()
place(ui, entries, c4)
Assert.not_nil(c4.timer)
Linked.cancel(c4)
Assert.is_nil(c4.timer)
found = {}
Stubs.flush()
Assert.len(found, 0)

-- 拉取：当前页附近的章后台拉；拉到前不交，拉到后 redraw；同章不重复请求。
local source = { id = "wechat", calls = {}, pending = {}, toc = chapters, current = true }
function source:paragraphHotspotsAsync(identity, cb)
    self.calls[#self.calls + 1] = identity
    self.pending[#self.pending + 1] = cb
    return { cancel = function() self.cancelled = (self.cancelled or 0) + 1 end }
end
document.page = 3
local wechat_toc = { { idx = 7, uid = "70", title = "一", words = 100 } }
cache = Linked.newCache()
local redraws = 0
local function redraw() redraws = redraws + 1 end
Assert.len(Linked.entries(ui, source, "834464", wechat_toc, cache, redraw), 0)
Assert.len(source.calls, 1)
Assert.eq(source.calls[1].chapter_idx, 7)
Assert.eq(source.calls[1].stable_id, "834464")
Assert.eq(source.calls[1].source_id, "wechat")
Assert.eq(source.calls[1].source, source)
Linked.entries(ui, source, "834464", wechat_toc, cache, redraw)
Assert.len(source.calls, 1, "在飞不重复请求")
source.pending[1]({ { text = "甲", range = "1-3" } })
Assert.eq(redraws, 1)
local got = Linked.entries(ui, source, "834464", wechat_toc, cache, redraw)
Assert.len(got, 1)
Assert.eq(got[1].spot.range, "1-3")
Assert.eq(got[1].identity.chapter_idx, 7)
Assert.len(source.calls, 1, "已拉到的不再请求")

-- 失败：RETRY 秒内不再请求，到点重试。
local clock = os.time()
local real_time = os.time
os.time = function() return clock end
local cache2 = Linked.newCache()
Linked.entries(ui, source, "834464", wechat_toc, cache2, redraw)
source.pending[2](nil, "offline")
Assert.eq(redraws, 1, "失败不重画")
Linked.entries(ui, source, "834464", wechat_toc, cache2, redraw)
Assert.len(source.calls, 2, "刚失败不重试")
clock = clock + 60
Linked.entries(ui, source, "834464", wechat_toc, cache2, redraw)
Assert.len(source.calls, 3, "过 60 秒重试")
os.time = real_time

-- 同步回调（磁盘缓存命中）：句柄不覆盖结果。
local sync_source = { id = "wechat" }
function sync_source:paragraphHotspotsAsync(_identity, cb)
    cb({ { text = "乙", range = "4-5" } })
    return { cancel = function() end }
end
local cache3 = Linked.newCache()
Linked.entries(ui, sync_source, "834464", wechat_toc, cache3, redraw)
Assert.is_nil(next(cache3.loading))
Assert.len(Linked.entries(ui, sync_source, "834464", wechat_toc, cache3, redraw), 1)

-- 取消：在飞的取消，已拉到的保留。
Linked.cancel(cache2)
Assert.eq(source.cancelled, 1)
Assert.is_nil(next(cache2.loading))
Assert.not_nil(cache.hotspots["834464\0" .. "70"])

-- 目录：旧格式（无字数）先强制重拉。
function source:loadTocAsync(book, cb)
    self.toc_book = book
    cb(self.toc)
    return { cancel = function() end }
end
function source:isTocCurrent() return self.current end
function source:refreshTocAsync(_book, cb)
    self.refreshed = true
    cb(self.toc)
    return { cancel = function() end }
end
local fetched
Linked.tocAsync(source, "834464", function(value) fetched = value end)
Assert.eq(fetched, chapters)
Assert.eq(source.toc_book.stable_id, "834464")
Assert.is_nil(source.refreshed)
source.current = false
Linked.tocAsync(source, "834464", function(value) fetched = value end)
Assert.is_true(source.refreshed)

-- 目标：没关联、不支持、没开关、没登录都不出；键只认书目。
local stored = {}
ui.doc_settings = {
    readSetting = function(_self, key) return stored[key] end,
    saveSetting = function(_self, key, value) stored[key] = value end,
    delSetting = function(_self, key) stored[key] = nil end,
}
source.on, source.logged_in = true, true
function source:paragraphReviewsEnabled() return self.on end
function source:configured() return self.logged_in end
package.loaded["source.registry"] = { resolve = function() return source end }

Assert.is_nil(Linked.target(ui, Linked.newCache(), redraw))
Linked.set(ui, { book_id = "834464", title = "活着", author = "余华" })
Assert.eq(Linked.get(ui).book_id, "834464")
local target = Linked.target(ui, Linked.newCache(), redraw)
Assert.eq(target.key, "link\0" .. "834464")
source.on = false
Assert.is_nil(Linked.target(ui, Linked.newCache(), redraw))
source.on, source.logged_in = true, false
Assert.is_nil(Linked.target(ui, Linked.newCache(), redraw))
source.logged_in = true
Assert.is_false(Linked.supported({ getPageXPointer = function() end }), "PDF 没有 findText")
Linked.set(ui, nil)
Assert.is_nil(Linked.get(ui))
Assert.is_nil(Linked.target(ui, Linked.newCache(), redraw))

-- 诡秘之主第一章那段长段评：本地 ASCII 省略号、全角缩进、跨页开头都能对上；两版有错字时记日志不标。
-- 真异步：绘制只起子进程不扫页；回包后收下定位、重画。翻走时旧页的在飞扫描被取消。
do
    local deferred, cancelled = nil, 0
    local real = package.loaded["workers.job"]
    package.loaded["workers.job"] = { run = function(worker, opts)
        local result = worker()
        deferred = function() opts.on_done(result) end
        return { settled = false, cancel = function() cancelled = cancelled + 1 deferred = nil end }
    end }
    document.page, found, scan_redraws = 3, {}, 0
    local c = Linked.newCache()
    Assert.len(place(ui, entries, c), 0, "没回包前不标")
    Assert.is_nil(c.scanned[3])
    deferred()
    Assert.eq(scan_redraws, 1)
    Assert.len(place(ui, entries, c), 2, "回包后有框")
    document.page = 5
    place(ui, entries, c)
    Assert.eq(cancelled, 0)
    Linked.cancel(c)
    Assert.eq(cancelled, 1, "cancel 撤在飞扫描")
    package.loaded["workers.job"] = real
    document.page = 3
end

do
    local para = "　　看来我还没有真醒，还在梦里......等下说不定还会出现自以为已经醒了，实际依然在睡的情况......对类似遭遇不算陌生的周明瑞竭力集中意志，以彻底摆脱黑暗和迷幻的桎梏。\n"
    local quote = "看来我还没有真醒，还在梦里……等下说不定还会出现自以为已经醒了，实际依然在睡的情况……对类似遭遇不算陌生的周明瑞竭力集中意志，以彻底摆脱黑暗和迷幻的桎梏。"
    local cut = para:find("等下", 1, true)
    local book = { "前一页的文字。\n" .. para:sub(1, cut - 1), para:sub(cut) .. "　　然而，半睡半醒之时。\n", "后一页。" }
    local logs, Log = {}, package.loaded["utils.log"]
    local info = Log.info
    Log.info = function(...) logs[#logs + 1] = table.concat({ ... }, " ", 1, 2) end
    local pattern
    local doc = setmetatable({ page = 2, getPageCount = function() return #book end,
        getTextFromXPointers = function(_self, a) return book[tonumber(a)] end,
        getPageXPointer = function(_self, p) return tostring(p) end,
        findText = function(_self, pat) pattern = pat return { { start = "1", ["end"] = "2" } } end,
        getPageFromXPointer = function(_self, xp) return tonumber(xp) end,
    }, { __index = document })
    local view = { document = doc, view = ui.view, getCurrentPage = function() return doc.page end }
    for _idx, case in ipairs({ { quote, 1 }, { quote:gsub("……", "..."), 1 } }) do
        Assert.len(place(view, { entry(case[1]) }, Linked.newCache()), case[2], "长原句跨页、省略号不同仍标")
        Assert.eq(pattern, para:sub(7, -5), "截回本地原文交 findText（去首尾标点）")
    end
    local typo = entry((quote:gsub("桎梏", "桔梏")))
    Assert.len(place(view, { typo }, Linked.newCache()), 0, "错字对不上不标")
    Assert.eq(logs[#logs], "book.reviews unmatched differs", "记下对不上的原因")
    Log.info = info
end

-- 候选章上限可调（借段评取 8）
do
    local many = {}
    for i = 1, 20 do many[i] = { idx = i, uid = tostring(i), title = "x" .. i, words = 1 } end
    Assert.len(Linked.candidates(many, {}, 0.5), 2)
    local wide = {}
    for i = 1, 100 do wide[i] = { idx = i, uid = tostring(i), title = "y" .. i, words = 1 } end
    Assert.len(Linked.candidates(wide, {}, 0.5), 6, "默认 6 章")
    Assert.len(Linked.candidates(wide, {}, 0.5, 8), 8)
end

-- 本章锚点：按字数取章中点；没字数按章序号
do
    local at, title = Linked.anchorOf({ { idx = 1, words = 100, title = "一" }, { idx = 2, words = 300, title = "二" } }, 2)
    Assert.eq(at, 0.625)
    Assert.eq(title, "二")
    Assert.eq(Linked.anchorOf({ { idx = 1, title = "" }, { idx = 2, title = "" }, { idx = 3, title = "" }, { idx = 4, title = "" } }, 2), 0.375)
    Assert.eq(Linked.anchorOf({}, 2), 0)
end

-- 章会话关联按书存（settings/reviews.lua 的 chapter_links），不跟着章文件
do
    local id = { source_id = "jdread", stable_id = "jd1", chapter_idx = 3 }
    Assert.is_nil(Linked.getFor(id))
    Linked.setFor(id, { book_id = "pub1", title = "书" })
    Assert.eq(Linked.getFor({ source_id = "jdread", stable_id = "jd1", chapter_idx = 9 }).book_id, "pub1", "换章仍在")
    Assert.is_nil(Linked.getFor({ source_id = "wechat", stable_id = "jd1" }), "键带源 id")
    Linked.setFor(id, nil)
    Assert.is_nil(Linked.getFor(id))
end

-- 借热点：属主源目录算锚点，到关联书目录挑章，热点记上归属章
do
    local own = { toc = { { idx = 1, words = 50, title = "一" }, { idx = 2, words = 50, title = "二" } } }
    function own:loadTocAsync(_book, cb) cb(self.toc); return { cancel = function() end } end
    local wechat = { id = "wechat", asked = {} }
    function wechat:loadTocAsync(_book, cb) cb({ { idx = 5, uid = "u5", title = "二", words = 10 } }); return { cancel = function() end } end
    function wechat:isTocCurrent() return true end
    function wechat:paragraphHotspotsAsync(identity, cb)
        self.asked[#self.asked + 1] = identity
        cb({ { range = "3-4", text = "句" } })
        return { cancel = function() end }
    end
    local got
    Linked.chapterHotspotsAsync(wechat, { source_id = "jdread", stable_id = "jd1", chapter_idx = 2, source = own },
        { book_id = "pub1" }, function(list) got = list end)
    Assert.len(wechat.asked, 1)
    Assert.eq(wechat.asked[1].stable_id, "pub1")
    Assert.eq(wechat.asked[1].chapter_idx, 5, "章名对上")
    Assert.eq(got[1].chapter_idx, 5)
end

