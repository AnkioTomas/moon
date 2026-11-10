--[[-- features.reviews.marks：章会话按需拉热点、只标屏上句子、点按打开段评。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
local opened
package.preload["features.reviews.sheet"] = function()
    return { open = function(id, spot) opened = { identity = id, spot = spot } end }
end
package.preload["l10n"] = function() return { apply = function() end } end

-- 子进程定位同步跑完。
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            opts.on_done(worker())
            return { cancel = function() end }
        end,
    }
end

local session
package.preload["reader.session"] = function()
    return { current = function() return session end }
end

-- 假源：只登记调用，回调由用例手动触发。
local source = { enabled = true, fetches = {} }
function source:paragraphReviewsEnabled() return self.enabled end
function source:paragraphHotspotsAsync(identity, cb)
    self.fetches[#self.fetches + 1] = { identity = identity, cb = cb }
    return { cancel = function() self.cancelled = (self.cancelled or 0) + 1 end }
end
-- 定位桩：原样交回（用例直接给出 pos），记下定位用的 HTML。
function source:locateHotspots(hotspots, html)
    self.located_html = html
    return hotspots
end

local identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 3, source = source }
session = { identity = identity }

local boxes = {
    ["a0"] = { { x = 10, y = 10, w = 50, h = 20 }, { x = 0, y = 40, w = 30, h = 20 } },
    ["b0"] = { { x = 10, y = 500, w = 50, h = 20 } }, -- 屏外
    ["c0"] = { { x = 10, y = 10, w = 50, h = 20 } },
}
-- c 句在第 5 页：当前第 1 页时不该去取它的屏幕框。
local pages = { a0 = 1, a1 = 1, b0 = 1, b1 = 2, c0 = 5, c1 = 5 }
local render_hash, page_lookups, box_lookups = 1, 0, {}
local chapter_file = os.tmpname()
local f = assert(io.open(chapter_file, "wb"))
f:write("<p>本章</p>")
f:close()

local registered = {}
local ui = {
    dialog = {},
    view = {
        dimen = { w = 100, h = 100 },
        registerViewModule = function(_self, name, module) registered.module = { name, module } end,
    },
    document = {
        info = {},
        file = chapter_file,
        getCurrentPos = function() return 0 end,
        getDocumentRenderingHash = function() return render_hash end,
        getPageFromXPointer = function(_self, xp)
            page_lookups = page_lookups + 1
            return pages[xp]
        end,
        getScreenBoxesFromPositions = function(_self, pos0)
            box_lookups[pos0] = (box_lookups[pos0] or 0) + 1
            return boxes[pos0]
        end,
    },
    getCurrentPage = function() return 1 end,
    registerTouchZones = function(_self, zones) registered.zones = zones end,
}

local Marks = require("features.reviews.marks")
Marks.install(ui)
Marks.install(ui)
local marks = ui._book_reviews_marks
Assert.eq(registered.module[1], "book_page_marks")
Assert.eq(registered.module[2], ui._book_page_marks)
Assert.eq(ui._book_page_marks.layers[1].layer, marks)
Assert.len(ui._book_page_marks.layers, 1, "重复 install 不重复登记图层")
Assert.eq(registered.zones[1].id, "book_page_marks_tap")

-- 首帧发起本章拉取，未就绪前不画；回来后在当前章节文件上定位。
marks:updateView()
marks:updateView()
Assert.len(source.fetches, 1, "同一章只拉一次")
Assert.eq(source.fetches[1].identity, identity)
Assert.len(marks.current, 0)

source.fetches[1].cb({
    { range = "1-5", text = "甲", total = 12, pos0 = "a0", pos1 = "a1" },
    { range = "9-12", text = "乙", total = 3, pos0 = "b0", pos1 = "b1" },
    { range = "20-22", text = "丙", total = 1, pos0 = "c0", pos1 = "c1" },
})
Assert.eq(source.located_html, "<p>本章</p>")
marks:updateView()
Assert.len(marks.current, 1, "屏外句子不标")
Assert.eq(marks.current[1].spot.total, 12)
Assert.is_nil(marks.current[1].count, "不显示段评数")
Assert.len(marks.current[1].boxes, 2)
Assert.eq(marks:marks(), marks.current)
Assert.is_false(marks.current[1].solid, "默认虚线")
local review_conf = require("utils.settings").get("features.reviews")
review_conf.book_reviews_mark_style = "solid"
Assert.is_true(marks:marks()[1].solid, "改样式不用等翻页")
review_conf.book_reviews_mark_style = "dashed"
Assert.is_nil(box_lookups.c0, "远页句子不取屏幕框")
Assert.eq(page_lookups, 6, "每句起止页各查一次")

-- 页码缓存：同一排版不重查；排版指纹变了重查。
marks.render_key = nil
marks:updateView()
Assert.eq(page_lookups, 6)
render_hash = 2
marks.render_key = nil
marks:updateView()
Assert.eq(page_lookups, 12, "排版变了重算页码")

-- 没有 getDocumentRenderingHash 时不崩溃；仍能按 xpointer 画已定位的句子。
do
    local saved = ui.document.getDocumentRenderingHash
    ui.document.getDocumentRenderingHash = nil
    marks.spans, marks.spans_hash, marks.render_key = nil, nil, nil
    local before = page_lookups
    marks:updateView()
    Assert.len(marks.current, 1, "无排版指纹仍画出当前页标记")
    Assert.eq(page_lookups, before + 6)
    marks.render_key = nil
    marks:updateView()
    Assert.eq(page_lookups, before + 6, "无指纹时复用已算的页码")
    ui.document.getDocumentRenderingHash = saved
end

-- 连换算页码 / 屏幕框的接口都没有：跳过标记，不在绘制路径上崩溃。
do
    local saved_page, saved_boxes = ui.document.getPageFromXPointer, ui.document.getScreenBoxesFromPositions
    ui.document.getPageFromXPointer, ui.document.getScreenBoxesFromPositions = nil, nil
    marks.spans, marks.spans_hash, marks.render_key = nil, nil, nil
    marks:updateView()
    Assert.len(marks.current, 0)
    ui.document.getPageFromXPointer, ui.document.getScreenBoxesFromPositions = saved_page, saved_boxes
    marks.spans, marks.spans_hash, marks.render_key = nil, nil, nil
    marks:updateView()
    Assert.len(marks.current, 1, "接口恢复后仍能画标记")
end

-- 点按回调打开该句段评。
marks.current[1].tap()
Assert.eq(opened.spot.range, "1-5")
Assert.eq(opened.identity, identity)

-- 段评首页确认总数为零后，关窗重绘立即去掉本次会话里的旧标记。
opened.spot.total = 0
Assert.len(marks:marks(), 0)
marks.render_key = nil
Assert.len(marks:marks(), 0, "视口变化不能让空标记复活")

-- 换章：清掉旧标记、取消在飞请求。
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 4, source = source }
session = { identity = identity }
marks:updateView()
Assert.len(source.fetches, 2)
Assert.len(marks.current, 0)
marks:updateView()
local cancelled_before = source.cancelled or 0
session = { identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 5, source = source } }
marks:updateView()
Assert.eq(source.cancelled, cancelled_before + 1, "换章取消在飞请求")
Assert.len(source.fetches, 3)

-- 拉取失败（含离线）：60 秒内不重试，到点再拉。
local clock = os.time()
local real_time = os.time
os.time = function() return clock end
source.fetches[3].cb(nil, "offline")
marks:updateView()
Assert.len(source.fetches, 3)
Assert.len(marks.current, 0)
clock = clock + 60
marks:updateView()
Assert.len(source.fetches, 4, "到点重试")
os.time = real_time

-- 关掉开关、非章节会话、不提供段评的源：都不标、点按透传。
source.enabled = false
marks:updateView()
Assert.len(marks:marks(), 0)
source.enabled = true
session = { identity = { source_id = "wechat", stable_id = "b1", source = source } }
marks:updateView()
Assert.len(source.fetches, 4)
session = { identity = { source_id = "local", stable_id = "x", chapter_idx = 1, source = {} } }
Assert.len(marks:marks(), 0)
session = nil
marks:updateView()
Assert.len(source.fetches, 4)
os.remove(chapter_file)

-- 关联书：目标来自 Linked.target；fetch 一次，place 每次视口变化调用；某章到了 redraw 重算。
local Linked = require("features.reviews.linked")
local real_target = Linked.target
local placed, redraw_fn = 0, nil
local spot = { range = "7-9", text = "丁" }
local link_identity = { source_id = "wechat", stable_id = "834464", chapter_idx = 2 }
local toc_fetches = 0
Linked.target = function(target_ui, cache, redraw)
    Assert.eq(target_ui, ui)
    Assert.not_nil(cache.hotspots)
    redraw_fn = redraw
    return {
        key = "link\0" .. "834464",
        fetch = function(cb)
            toc_fetches = toc_fetches + 1
            cb({ { idx = 2 } })
            return { cancel = function() end }
        end,
        place = function(toc)
            Assert.eq(toc[1].idx, 2)
            placed = placed + 1
            return { { entry = { identity = link_identity, spot = spot }, boxes = { { x = 1, y = 1, w = 9, h = 9 } } } }
        end,
    }
end
session = { identity = { source_id = "local", stable_id = "/b.epub" } }
marks:updateView()
Assert.eq(toc_fetches, 1)
Assert.eq(placed, 1)
Assert.len(marks.current, 1)
marks:updateView()
Assert.eq(placed, 1, "视口没变不重算")
redraw_fn()
marks:updateView()
Assert.eq(placed, 2, "某章热点到了重算")
Assert.eq(toc_fetches, 1, "目录只拉一次")
marks.current[1].tap()
Assert.eq(opened.identity, link_identity)
Assert.eq(opened.spot, spot)
Linked.target = real_target

-- 借段评（贡献者设计）：本章自己没有热点且关联了书城版 → 借关联书的热点；点开用关联书那一章的身份。
local real_get_for, real_borrow = Linked.getFor, Linked.chapterHotspotsAsync
local borrows = {}
Linked.getFor = function(id) return id.stable_id ~= "jd2" and { book_id = "pub1" } or nil end
Linked.chapterHotspotsAsync = function(src, id, link, cb)
    borrows[#borrows + 1] = { src = src, id = id, link = link }
    cb({ { range = "1-5", text = "甲", total = 2, pos0 = "a0", pos1 = "a1", chapter_idx = 7 } })
    return { cancel = function() end }
end
source.enabled = true
identity = { source_id = "wechat", stable_id = "CB_1", chapter_idx = 6, source = source }
session = { identity = identity }
marks:updateView()
source.fetches[#source.fetches].cb({})
marks:updateView()
Assert.len(borrows, 1, "本章为空才借")
Assert.eq(borrows[1].src, source)
Assert.len(marks.current, 1)
marks.current[1].tap()
Assert.eq(opened.identity.stable_id, "pub1", "借来的句子用关联书身份")
Assert.eq(opened.identity.chapter_idx, 7, "且是热点所属章")

-- 本章自己有热点：不借
identity = { source_id = "wechat", stable_id = "CB_1", chapter_idx = 8, source = source }
session = { identity = identity }
marks:updateView()
source.fetches[#source.fetches].cb({ { range = "9-9", text = "乙", total = 1, pos0 = "a0", pos1 = "a1" } })
marks:updateView()
Assert.len(borrows, 1)
marks.current[1].tap()
Assert.eq(opened.identity, identity)

-- 京东读书章会话：自己没有段评，关联了就直接借微信书城版
local wechat = { id = "wechat" }
function wechat:configured() return true end
function wechat:paragraphReviewsEnabled() return true end
function wechat:locateHotspots(hotspots) return hotspots end
local real_registry = package.loaded["source.registry"]
package.loaded["source.registry"] = { resolve = function() return wechat end }
session = { identity = { source_id = "jdread", stable_id = "jd1", chapter_idx = 2, source = {} } }
marks:updateView()
Assert.len(borrows, 2)
Assert.eq(borrows[2].src, wechat, "借段评走微信源")
Assert.len(marks.current, 1)
marks.current[1].tap()
Assert.eq(opened.identity.source, wechat)
session = { identity = { source_id = "jdread", stable_id = "jd2", chapter_idx = 2, source = {} } }
marks:updateView()
Assert.len(marks:marks(), 0, "没关联不标")
package.loaded["source.registry"] = real_registry
Linked.getFor, Linked.chapterHotspotsAsync = real_get_for, real_borrow

-- 章末目标不读文档文件：短篇整本 EPUB 与长篇章节都只在文档末页显示。
local end_source = { calls = 0, enabled = false }
function end_source:paragraphReviewsEnabled() return self.enabled end
function end_source:chapterReviewHotspotsAsync(_identity, cb)
    self.calls = self.calls + 1
    cb({ { range = "section", text = "本章", total = 4, badge = "4",
        heading = "章节评论", anchor = "moon-chapter-reviews" } })
    return { cancel = function() end }
end
local current_page, end_lookups = 1, 0
ui.getCurrentPage = function() return current_page end
ui.document.getVisiblePageCount = function() return 1 end
ui.document.getPageCount = function() return 5 end
ui.document.getPageMargins = function() return { right = 0, bottom = 0 } end
ui.document.getNormalizedXPointer = function() return nil end
ui.document.getTextFromPositions = function(_self, first, last, no_selection)
    end_lookups = end_lookups + 1
    Assert.eq(first, last)
    Assert.eq(first.x, 99)
    Assert.eq(first.y, 99)
    Assert.is_true(no_selection, "定位不改变原生选区")
    return { sboxes = { { x = 1, y = 10, w = 20, h = 10 }, { x = 1, y = 30, w = 30, h = 10 } } }
end
identity = { source_id = "zhihu", stable_id = "1/2", source = end_source }
session = { identity = identity }
Assert.len(marks:marks(), 0)
Assert.eq(end_source.calls, 0, "关闭章末段评时不发请求")
end_source.enabled = true
Assert.len(marks:marks(), 0, "短篇前面的页不显示章末评论")
Assert.eq(end_lookups, 0, "没到末页不问文本框")
current_page = 5
Assert.len(marks:marks(), 1)
Assert.eq(end_source.calls, 1, "翻页不重拉评论")
Assert.eq(marks.current[1].badge, "4")
Assert.eq(marks.current[1].heading, "章节评论")
Assert.eq(marks.current[1].boxes[1].y, 50, "旧缓存的入口在正文下方，不贴在最后一行上")
marks.current[1].tap()
Assert.eq(opened.identity, identity)
Assert.eq(opened.spot.range, "section")
identity = { source_id = "zhihu", stable_id = "1", chapter_idx = 2, source = end_source }
session = { identity = identity }
Assert.len(marks:marks(), 1)
Assert.eq(end_source.calls, 2, "长篇换章使用新目标")
marks.current[1].tap()
Assert.eq(opened.identity.chapter_idx, 2)

current_page = 4
ui.document.getVisiblePageCount = function() return 2 end
Assert.len(marks:marks(), 1, "双栏的右栏到达末页也显示入口")
local scroll_pos = 409
ui.view.view_mode = "scroll"
ui.view.footer = { getHeight = function() return 10 end }
ui.document.info = { doc_height = 500 }
ui.document.getCurrentPos = function() return scroll_pos end
Assert.len(marks:marks(), 0, "滚动模式尚未到底不显示入口")
scroll_pos = 410
Assert.len(marks:marks(), 1, "滚动到底后显示入口，不依赖顶端页码恰好为末页")
end_source.enabled = false
Assert.len(marks:marks(), 0, "关闭开关立即移除章末入口")
Assert.eq(end_source.calls, 2, "关闭不触发重新拉取或借其它源")

end_source.enabled = true
Assert.len(marks:marks(), 1, "再次打开开关即恢复入口")
Assert.eq(end_source.calls, 3)

ui.document.getNormalizedXPointer = function(_document, xp)
    if xp == "#moon-chapter-reviews" then return "/html/body/div" end
end
ui.document.getScreenPositionFromXPointer = function() return 45, 3 end
marks.render_key = nil
Assert.eq(marks:marks()[1].boxes[1].y, 45, "新缓存直接使用排版预留区，不猜正文结束位置")

ui.document.getNormalizedXPointer = function(_document, xp)
    if xp == "/body/DocFragment" or xp == "/body/DocFragment[1]" or xp == "/body/DocFragment[2]" then return xp end
    if xp == "#_doc_fragment_1_ moon-chapter-reviews" then return "/body/DocFragment[2]/body/div" end
end
ui.document.getPageXPointer = function() return "/body/DocFragment[1]/body/p/text().0" end
marks.render_key = nil
Assert.eq(marks:marks()[1].boxes[1].y, 45, "EPUB 末页可同时包含多个 spine，仍能找到最后一个的章评区")
marks.data[1].total, marks.data[1].badge = 0, "0"
marks.render_key = nil
Assert.len(marks:marks(), 1, "独立章节评论区显示 0，不被段落热点的零条过滤规则删掉")

-- 同一源同时提供段评和章末评论：两种目标都保留，仍只有一个公共标记图层。
ui.view.view_mode = "page"
ui.document.getVisiblePageCount = function() return 1 end
current_page = 5
pages.a0, pages.a1 = 5, 5
ui.document.getCurrentPos = function() return 0 end
source.chapterReviewHotspotsAsync = end_source.chapterReviewHotspotsAsync
source.calls, source.enabled = 0, true
session = { identity = { source_id = "qidian", stable_id = "combined", chapter_idx = 1, source = source } }
marks:updateView()
source.fetches[#source.fetches].cb({ { range = "1", text = "段落", total = 2, pos0 = "a0", pos1 = "a1" } })
marks:updateView()
Assert.len(marks.current, 2, "增加章末能力不能挤掉段评")
Assert.eq(source.calls, 1)
Assert.eq(marks.current[1].spot.range, "1")
Assert.eq(marks.current[2].spot.range, "section")
source.chapterReviewHotspotsAsync = nil

-- 固定版式没有 CREngine 的文字、页边距和 xpointer 接口。
package.loaded["ui.themes"] = { px = function(n) return n end }
ui.document = { info = { has_pages = true, number_of_pages = 5 } }
session = { identity = { source_id = "kuaikan", stable_id = "comic", chapter_idx = 1, source = end_source } }
current_page = 1
Assert.len(marks:marks(), 0, "漫画前页不显示章评入口")
current_page = 5
Assert.len(marks:marks(), 1, "漫画末页通过固定页数显示章评")
Assert.eq(marks.current[1].boxes[1].y, 62, "入口不盖住底部状态栏")
marks.current[1].tap()
Assert.eq(opened.identity.source_id, "kuaikan")
Assert.eq(opened.identity.chapter_idx, 1)
current_page = 4
Assert.len(marks:marks(), 0, "翻回前页立即移除漫画章评入口")
end_source.enabled = false
current_page = 5
Assert.len(marks:marks(), 0, "关闭开关后漫画末页也不显示")
