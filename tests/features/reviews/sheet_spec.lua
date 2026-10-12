--[[-- features.reviews.sheet：按卡片高度分页，第一页的原句引用也占高度。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
require("support.modal_stub").install()
package.preload["l10n"] = function() return { apply = function() end } end
for _idx, name in ipairs({ "ui.themes", "ui.themes.widgets.box", "ui.themes.widgets.icon",
        "ui.themes.widgets.pager", "ui.themes.widgets.text", "ui.themes.widgets.titlebar" }) do
    package.preload[name] = function() return {} end
end

local Sheet = require("features.reviews.sheet")

local function widget(h) return { getSize = function() return { w = 10, h = h } end } end

--- 引用高 quote_h，卡片高依次为 heights，卡片间隔 10，正文区高 100。
local function paginate(quote_h, heights)
    local fake = { items = {}, body_h = 100 }
    for i = 1, #heights do fake.items[i] = {} end
    function fake.quote() return widget(quote_h) end
    function fake.card(_self, i) return widget(heights[i]) end
    function fake.gap() return 10 end
    Sheet.paginate(fake)
    return fake.pages
end

-- 引用 + 首条放不下：首条挪到第二页，第一页只剩引用。
local pages = paginate(60, { 80, 10 })
Assert.len(pages, 2)
Assert.eq(pages[1][1], 1)
Assert.eq(pages[1][2], 0)
Assert.eq(pages[2][1], 1)
Assert.eq(pages[2][2], 2)

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
