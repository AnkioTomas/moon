--[[-- features.reviews.sheet：按卡片高度分页，第一页的原句引用也占高度。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
require("support.modal_stub").install()
package.preload["l10n"] = function() return { apply = function() end } end
for _idx, name in ipairs({ "ui.themes", "ui.themes.widgets.box", "ui.themes.widgets.icon", "ui.themes.widgets.image",
        "ui.themes.widgets.pager", "ui.themes.widgets.text", "ui.themes.widgets.titlebar",
        "ui/gesturerange", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/verticalgroup" }) do
    package.preload[name] = function() return {} end
end

local Sheet = require("features.reviews.sheet")

local function widget(h) return { getSize = function() return { w = 10, h = h } end } end

--- 引用高 quote_h，卡片自然高依次为 heights（按所在页可用高度截断），卡片间隔 10，正文区高 100。
local function paginate(quote_h, heights)
    local fake = { items = {}, body_h = 100 }
    for i = 1, #heights do fake.items[i] = {} end
    function fake.quote() return widget(quote_h) end
    function fake.card(_self, i, avail) return widget(math.min(heights[i], avail or 100)) end
    function fake.gap() return 10 end
    Sheet.paginate(fake)
    return fake.pages
end

-- 引用 + 首条自然高放不下：首条按首页剩余高度（100-60）截断留在第一页，第二条去第二页。
local pages = paginate(60, { 80, 10 })
Assert.len(pages, 2)
Assert.eq(pages[1][1], 1)
Assert.eq(pages[1][2], 1)
Assert.eq(pages[2][1], 2)
Assert.eq(pages[2][2], 2)

do
    local callback
    local spot = { range = "old", text = "原句", total = 5 }
    local fake = setmetatable({
        identity = { source = { paragraphReviewPageAsync = function(_self, _identity, _range, _max_idx, cb)
            callback = cb
            return { cancel = function() end }
        end } },
        spot = spot, more = true, max_idx = 0, items = {}, page = 1,
        paginate = function(self) self.pages = { { 1, #self.items } } end,
        refresh = function() end,
    }, { __index = Sheet })
    fake:load()
    Assert.eq(spot.total, 5, "请求回来前不修改标记")
    callback({ items = {}, total = 0, max_idx = 0, more = false })
    Assert.eq(spot.total, 0, "首页明确归零同步更新页内标记")
    Assert.is_true(fake.loaded)
    Assert.is_false(fake.more)
end

do -- 回复页走 paragraphReviewRepliesAsync，评论 id 在 spot.range
    local seen
    local fake = setmetatable({
        identity = { source = { paragraphReviewRepliesAsync = function(_self, _identity, review_id, max_idx, cb)
            seen = { review_id, max_idx }
            cb({ items = { { id = "c", author = "a", content = "r", likes = 0, time = 1 } },
                total = 4, max_idx = 2, more = false })
            return { cancel = function() end }
        end } },
        spot = { range = "rev1", text = "父评论", total = 4 },
        reply_page = true, more = true, max_idx = 0, items = {}, page = 1,
        paginate = function(self) self.pages = { { 1, #self.items } } end,
        refresh = function() end,
    }, { __index = Sheet })
    fake:load()
    Assert.eq(seen[1], "rev1")
    Assert.eq(seen[2], 0)
    Assert.eq(fake.total, 4)
    Assert.len(fake.items, 1)
    Assert.eq(fake.max_idx, 2)
    Assert.is_false(fake.more)
end

do
    local offsets = {}
    local fake = setmetatable({
        identity = { source = { paragraphReviewPageAsync = function(_self, _identity, _range, offset, cb)
            offsets[#offsets + 1] = offset
            cb({ items = { { id = tostring(#offsets) } }, total = 2, max_idx = "sr1:opaque",
                more = #offsets == 1 })
        end } },
        spot = { range = "chapter", text = "本章", total = 2 },
        more = true, max_idx = 0, items = {}, page = 1,
        paginate = function(self) self.pages = { { 1, #self.items } } end,
        refresh = function() end,
    }, { __index = Sheet })
    fake:load()
    fake:load()
    Assert.eq(offsets[2], "sr1:opaque", "评论列表原样传回字符串游标")
    Assert.len(fake.items, 2)
    Assert.is_false(fake.more)
end

-- 放得下照常同页。
pages = paginate(20, { 30, 30 })
Assert.len(pages, 1)
Assert.eq(pages[1][2], 2)

-- 新页首条即使超高也只占一页，不产生空页。
pages = paginate(0, { 150, 20 })
Assert.len(pages, 2)
Assert.eq(pages[1][1], 1)
Assert.eq(pages[1][2], 1)

-- 没有段评也保留一页。
pages = paginate(20, {})
Assert.len(pages, 1)
Assert.eq(pages[1][2], 0)
