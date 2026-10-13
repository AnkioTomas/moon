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

-- 点按回调打开该句段评。
marks.current[1].tap()
Assert.eq(opened.spot.range, "1-5")
Assert.eq(opened.identity, identity)

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
