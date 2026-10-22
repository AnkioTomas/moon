--[[-- 统计页设置：选择显示哪些页面、每页显示哪些数据。目录与显隐规则在 desktop/pages/insight/layout.lua。
@module koplugin.book.desktop.pages.setting.insight
--]]

local Row = require("ui.themes.widgets.row")
local _ = require("gettext")

---@class BookSettingsInsight
local InsightSettings = {}

local function count(items)
    local n = 0
    for _idx, item in ipairs(items) do
        if item.checked then n = n + 1 end
    end
    return n
end

--- 多选弹窗：每次勾选立即落盘，关窗后刷新设置页。
---@param desktop table
---@param title string
---@param items table[] { text, checked, toggle = fun(): boolean|nil }
local function pick(desktop, title, items)
    for _idx, item in ipairs(items) do
        item.callback = function(_checked, it)
            if it.toggle() == false then
                it.checked = true
                require("ui.themes.widgets.toast"):new{ text = _("至少保留一个页面"), timeout = 2 }:show()
            end
        end
    end
    require("ui.themes.widgets.list"):new{
        title = title, centered = true, multi = true, items = items,
        close_callback = function() desktop:updateView() end,
    }:show()
end

---@param desktop table
---@param label string
---@param items table[]
---@return fun(iw: number): table
local function pickRow(desktop, label, items)
    return function(iw)
        return Row.widget({
            width = iw,
            title = label,
            status = string.format("%d / %d", count(items), #items),
            status_on = true,
            callback = function() pick(desktop, label, items) end,
        })
    end
end

--- 第一节选页面；第二节每个已显示的页面一行，点开选该页的数据卡片。
---@param desktop table
---@return table[]
function InsightSettings:sections(desktop)
    local Layout = require("desktop.pages.insight.layout")
    local pages, page_items, card_rows = Layout.catalog(), {}, {}
    for _idx, page in ipairs(pages) do
        page_items[#page_items + 1] = {
            text = page.label, checked = Layout.pageShown(page.id),
            toggle = function() return Layout.togglePage(page.id) end,
        }
        if Layout.pageShown(page.id) then
            local cards = {}
            for _idx2, card in ipairs(page.cards) do
                cards[#cards + 1] = {
                    text = card.label, checked = Layout.shown(page.id, card.id),
                    toggle = function() Layout.toggleCard(page.id, card.id) end,
                }
            end
            card_rows[#card_rows + 1] = pickRow(desktop, page.label, cards)
        end
    end
    return {
        { title = _("显示的页面"), rows = { pickRow(desktop, _("统计页面"), page_items) } },
        { title = _("各页显示的数据"), rows = card_rows },
    }
end

return InsightSettings
