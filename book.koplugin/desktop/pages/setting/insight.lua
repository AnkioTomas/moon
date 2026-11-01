--[[-- 统计页设置：选择显示哪些页面、每页显示哪些数据。目录与显隐规则在 desktop/pages/insight/layout.lua。
@module koplugin.book.desktop.pages.setting.insight
--]]

local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

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

--- 按源或按书清除本地阅读统计。不向远端发删除。
---@param desktop table
---@return fun(iw: number): table
local function clearRow(desktop)
    local function sourceName(id)
        local meta = require("source.registry").meta(id)
        return meta and meta.name or id
    end
    local function itemsFor(kind)
        local StatsDB = require("book.stats_db")
        local items = {}
        if kind == "source" then
            for _idx, id in ipairs(StatsDB.distinctSources()) do
                local name = sourceName(id)
                items[#items + 1] = { text = name, value = { source_id = id, label = name } }
            end
        else
            for _idx, book in ipairs(StatsDB.distinctBooks()) do
                items[#items + 1] = {
                    text = book.title or book.stable_id,
                    mandatory = sourceName(book.source_id),
                    value = {
                        source_id = book.source_id,
                        stable_id = book.stable_id,
                        label = book.title or book.stable_id,
                    },
                }
            end
        end
        if #items == 0 then
            items[1] = { text = _("没有可清除的统计"), enabled = false }
        end
        return items
    end
    local function confirm(value)
        local text = value.stable_id
            and T(_("清除《%1》的本地阅读统计？不影响云端。"), value.label)
            or T(_("清除「%1」的全部本地阅读统计？不影响云端。"), value.label)
        require("ui.themes.widgets.confirm"):new{
            text = text,
            ok_text = _("清除"),
            ok_callback = function()
                local ok = require("book.stats_db").deleteLocal(value.source_id, value.stable_id)
                if ok then
                    if desktop.home then desktop:onEvent("home_refresh") end
                    desktop:onEvent("stats_changed")
                    desktop:updateView()
                end
                require("ui.themes.widgets.toast"):new{
                    text = ok and _("已清除本地统计") or _("清除统计失败"),
                    timeout = 2,
                }:show()
            end,
        }:show()
    end
    return function(iw)
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "action", icon = "delete_sweep", title = _("清除统计"),
            subtitle = _("按源或按书清除，不影响云端"), status_on = true,
            callback = function()
                require("ui.themes.widgets.list"):new{
                    title = _("清除统计"),
                    items = itemsFor("source"),
                    tabs = {
                        tabs = {
                            { id = "source", text = _("按源"), icon = "source" },
                            { id = "book", text = _("按书"), icon = "menu_book" },
                        },
                        active = "source",
                        on_tab = itemsFor,
                    },
                    on_select = function(_value, item)
                        if item.value then confirm(item.value) end
                    end,
                }:show()
            end,
        })
    end
end

--- 导入 KOReader 自带统计插件的阅读记录；纯本地操作，不推给任何源。
---@param desktop table
---@return fun(iw: number): table
local function importRow(desktop)
    return function(iw)
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "action", icon = "download", title = _("导入 KOReader 统计"),
            subtitle = _("按书匹配书库，已有的记录不会重复导入"), status_on = true,
            callback = function()
                require("ui.themes.widgets.confirm"):new{
                    text = _("把 KOReader 自带统计插件的阅读记录导入月读？只导入书库里能对上的书。"),
                    ok_text = _("导入"),
                    ok_callback = function()
                        local toast = require("ui.themes.widgets.progress_dialog"):new{
                            title = _("导入 KOReader 统计"), text = _("正在导入…"), dismissable = false,
                        }
                        local counts, err = toast:showWhile(function()
                            require("ui/uimanager"):forceRePaint()
                            return require("book.stats_koreader").import()
                        end)
                        toast:close()
                        if not counts then
                            require("ui.themes.widgets.toast"):new{
                                text = err == "missing" and _("没有找到 KOReader 统计数据") or _("导入失败"),
                                timeout = 2,
                            }:show()
                            return
                        end
                        if counts.rows > 0 then
                            if desktop.home then desktop:onEvent("home_refresh") end
                            desktop:onEvent("stats_changed")
                            desktop:updateView()
                        end
                        require("ui.themes.widgets.toast"):new{
                            text = T(_("已导入 %1 本书的 %2 条记录，%3 本书在书库中未找到"),
                                counts.books, counts.rows, counts.unmatched),
                            timeout = 3,
                        }:show()
                    end,
                }:show()
            end,
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
        { title = _("统计页"), rows = {
            function(iw)
                local conf = Settings.get("desktop")
                local enabled = conf.insight_enabled ~= false
                return Row.widget({
                    width = iw, icon = "bar_chart", title = _("显示统计页"),
                    subtitle = _("在底栏显示统计入口，不影响阅读统计"),
                    toggle = enabled,
                    callback = function()
                        conf.insight_enabled = not enabled
                        Settings.save("desktop")
                        desktop:updateView()
                    end,
                })
            end,
            importRow(desktop),
            clearRow(desktop),
        } },
        { title = _("显示的页面"), rows = { pickRow(desktop, _("统计页面"), page_items) } },
        { title = _("各页显示的数据"), rows = card_rows },
    }
end

return InsightSettings
