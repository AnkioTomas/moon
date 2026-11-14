---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[--
阅读页栏组合页：预览 + 公共显示项；组件列表复用侧栏页面顺序的设置/上下按钮，
专属设置收敛到组件页。
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts) return opts end,
        choice = function(opts) return opts end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) return o end }
end
require("support.theme_stubs").install()
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end }
end
package.preload["ui.themes"] = function() return { px = function(n) return n end } end
package.preload["ui.themes.widgets.button"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/horizontalgroup"] = function()
    return { new = function(_, group) return group end }
end
package.preload["ui/widget/horizontalspan"] = function()
    return { new = function(_, span) return span end }
end
local overlay_pushes = {}
package.preload["desktop.pages.setting.overlay"] = function()
    return {
        push = function(desktop, spec)
            overlay_pushes[#overlay_pushes + 1] = { desktop = desktop, spec = spec }
        end,
    }
end

local bottom_calls = {}
package.preload["features.bars"] = function()
    return {
        topBarPreference = function() return true end,
        bottomBarPreference = function() return false end,
        setTopBarPreference = function() end,
        syncTopMargin = function() end,
        syncBottomHeight = function() end,
        setBottomBarPreference = function(enabled, ui)
            bottom_calls[#bottom_calls + 1] = { enabled = enabled, ui = ui }
        end,
    }
end
local ReaderUIStub = { instance = nil }
package.preload["apps/reader/readerui"] = function() return ReaderUIStub end

local catalogs = {
    top = {
        { id = "chapter", label = "章节", icon = "menu_book" },
        { id = "clock", label = "时钟", icon = "schedule" },
        { id = "battery", label = "电量", icon = "battery_full" },
    },
    bottom = {
        { id = "percent", label = "进度", icon = "percent" },
        { id = "progress_bar", label = "进度条", icon = "horizontal_rule" },
        { id = "title", label = "书名", icon = "title" },
    },
}
local layouts = {
    top = {
        { id = "chapter", align = "left" },
        { id = "clock", align = "right" },
    },
    bottom = {
        { id = "percent", align = "left" },
        { id = "progress_bar", align = "left" },
    },
}

local function slot(which, id)
    local list = layouts[which]
    for i = 1, #list do
        if list[i].id == id then
            return i, list[i].align, list[i].row == "down" and "down" or "up"
        end
    end
    return nil, nil
end

local function orderedCatalog(which)
    local catalog = catalogs[which]
    local by_id = {}
    for i = 1, #catalog do by_id[catalog[i].id] = catalog[i] end
    local out = {}
    for i = 1, #layouts[which] do
        local item = by_id[layouts[which][i].id]
        if item then
            out[#out + 1] = item
            by_id[layouts[which][i].id] = nil
        end
    end
    for i = 1, #catalog do
        if by_id[catalog[i].id] then out[#out + 1] = by_id[catalog[i].id] end
    end
    return out
end

local icons_on = true
local dividers = {}
local font = { top = nil, bottom = nil }
local top_height = 12
local percent_decimals = false
local thickness = nil
local stacked_on = false
local spins = {}
package.preload["ui.themes.widgets.spin"] = function()
    return { new = function(_, o) o.show = function(self) spins[#spins + 1] = self end; return o end }
end
package.preload["features.bars.layout"] = function()
    return {
        FONT_MIN = 8, FONT_MAX = 36, TOP_HEIGHT_MIN = 0, TOP_HEIGHT_MAX = 60,
        BAR_THICKNESS_MIN = 1, BAR_THICKNESS_MAX = 24,
        progressThickness = function() return thickness end,
        setProgressThickness = function(v) thickness = v end,
        progressBarHeight = function() return thickness or 8 end,
        themeProgressThickness = function() return 8 end,
        fontSize = function(which, fs)
            if which == "top" then return font.top or (fs and fs.text_font_size) or 14 end
            return (fs and fs.text_font_size) or font.bottom or 14
        end,
        topFontCustom = function() return font.top ~= nil end,
        setFontSize = function(which, v) font[which] = v end,
        topHeight = function() return top_height end,
        topMargin = function() return 0 end,
        bottomMargin = function() return 1 end,
        TOP_MARGIN_MIN = 0, TOP_MARGIN_MAX = 60, BOTTOM_MARGIN_MIN = 0, BOTTOM_MARGIN_MAX = 49,
        setTopHeight = function(v) top_height = v end,
        icons = function() return icons_on end,
        divider = function(which) return dividers[which] == true end,
        setDivider = function(which, on) dividers[which] = on end,
        percentDecimals = function() return percent_decimals end,
        setPercentDecimals = function(on) percent_decimals = on end,
        stackedPreferred = function() return stacked_on end,
        setStacked = function(on) stacked_on = on and true or false end,
        setRow = function(which, id, row)
            for i = 1, #layouts[which] do
                if layouts[which][i].id == id then layouts[which][i].row = row return end
            end
        end,
        rowPosition = function(which, id)
            local list = layouts[which]
            local row
            for i = 1, #list do
                if list[i].id == id then row = (list[i].row == "down") and "down" or "up" break end
            end
            if not row then return nil, nil, nil end
            local pos, count = 0, 0
            for i = 1, #list do
                local r = list[i].row == "down" and "down" or "up"
                if r == row then
                    count = count + 1
                    if list[i].id == id then pos = count end
                end
            end
            return pos, count, row
        end,
        moveInRow = function(which, id, delta)
            -- 测试里足够用全局对调。
            local list = layouts[which]
            for i = 1, #list do
                if list[i].id == id then
                    local j = i + delta
                    if j >= 1 and j <= #list then list[i], list[j] = list[j], list[i] end
                    return
                end
            end
        end,
        setIcons = function(on) icons_on = on end,
        replace = function() return true end,
        setReplace = function() end,
        get = function(which) return layouts[which] end,
        slot = slot,
        orderedCatalog = orderedCatalog,
        toggle = function(which, id)
            local list = layouts[which]
            for i = 1, #list do
                if list[i].id == id then
                    table.remove(list, i)
                    return
                end
            end
            list[#list + 1] = { id = id, align = "left" }
        end,
        move = function(which, id, delta)
            local list = layouts[which]
            for i = 1, #list do
                if list[i].id == id then
                    local j = i + delta
                    if j >= 1 and j <= #list then
                        list[i], list[j] = list[j], list[i]
                    end
                    return
                end
            end
        end,
        setAlign = function(which, id, align)
            for i = 1, #layouts[which] do
                if layouts[which][i].id == id then
                    layouts[which][i].align = align
                    return
                end
            end
        end,
    }
end
package.preload["features.bars.preview"] = function()
    return {
        build = function(width, which) return { kind = "preview", width = width, which = which } end,
        footerSettings = function()
            local ui = ReaderUIStub.instance
            local footer = ui and ui.document and ui.view and ui.view.footer
            if footer then return footer.settings, footer end
            return nil, nil
        end,
    }
end

local ReaderBar = require("features.bars.page")
local updates = 0
local desktop = { updateView = function() updates = updates + 1 end, settings = {} }
local page = ReaderBar:page(desktop, "top")
Assert.eq(page.preview(600).kind, "preview")
Assert.eq(page.preview(600).which, "top")
Assert.eq(#page.sections, 2)
Assert.eq(page.sections[1].title, "显示")
Assert.eq(page.sections[1].rows[1](600).title, "替代系统顶栏")
Assert.eq(page.sections[1].rows[2](600).title, "开启顶栏")
Assert.is_true(page.sections[1].rows[2](600).status_on)
Assert.eq(page.sections[1].rows[3](600).title, "组件图标")
Assert.is_true(page.sections[1].rows[3](600).status_on)
page.sections[1].rows[3](600).callback()
Assert.is_false(icons_on, "点一下关掉图标")
Assert.is_false(page.sections[1].rows[3](600).status_on)
Assert.eq(page.sections[1].rows[4](600).title, "分割线")
page.sections[1].rows[4](600).callback()
Assert.is_true(dividers.top, "点一下开分割线")
Assert.is_true(page.sections[1].rows[4](600).status_on)
-- 文字大小：顶栏未设置时跟随底栏；改完写入顶栏自己的值，不碰 KOReader 状态栏。
Assert.eq(page.sections[1].rows[5](600).title, "文字大小")
Assert.eq(page.sections[1].rows[5](600).status, "跟随底栏 · 14")
page.sections[1].rows[5](600).callback()
spins[#spins].callback(20)
Assert.eq(font.top, 20)
Assert.eq(page.sections[1].rows[5](600).status, "20")
-- 高度只在顶栏。
Assert.eq(page.sections[1].rows[6](600).title, "高度")
Assert.eq(page.sections[1].rows[6](600).status, "12")
page.sections[1].rows[6](600).callback()
spins[#spins].callback(24)
Assert.eq(top_height, 24)
Assert.eq(page.sections[1].rows[7](600).title, "边距")
Assert.eq(page.sections[2].title, "组件")

-- 组件行：图标、名称、设置、上移、下移；列表按布局顺序，未启用的跟在后面。
local function trail(row)
    return row.status
end
local function rowOf(which, index)
    return ReaderBar:page(desktop, which).sections[2].rows[index](600)
end

local first = page.sections[2].rows[1](600)
Assert.eq(first.icon, "menu_book")
Assert.eq(first.title, "章节")
Assert.is_false(first.chevron)
Assert.eq(first.callback, nil, "整行不绑回调，避免和右侧按钮抢手势")
local t1 = trail(first)
Assert.eq(t1[1].icon, "settings")
Assert.eq(t1[1].variant, "ghost")
Assert.eq(t1[1].width, 36)
Assert.eq(t1[1].height, 36)
Assert.eq(t1[2].width, 4)
Assert.eq(t1[3].icon, "arrow_upward")
Assert.eq(t1[3].variant, "ghost")
Assert.is_false(t1[3].enabled, "第一项不能上移")
Assert.eq(t1[5].icon, "arrow_downward")
Assert.is_true(t1[5].enabled, "第一项可以下移")

local second = page.sections[2].rows[2](600)
Assert.eq(second.title, "时钟")
Assert.is_true(trail(second)[3].enabled, "中间项可以上移")
Assert.is_false(trail(second)[5].enabled, "布局最后一项不能下移")

local unused = page.sections[2].rows[3](600)
Assert.eq(unused.title, "电量")
Assert.is_false(trail(unused)[3].enabled, "未启用不能上移")
Assert.is_false(trail(unused)[5].enabled, "未启用不能下移")
Assert.is_true(trail(unused)[1].enabled, "未启用仍可开设置")

-- 下移立即落盘；刷新后列表顺序跟着变。
updates = 0
t1[5].callback()
Assert.eq(layouts.top[1].id, "clock")
Assert.eq(layouts.top[2].id, "chapter")
Assert.eq(layouts.top[2].align, "left", "移动不丢对齐")
Assert.eq(updates, 1, "排序后刷新设置页")
Assert.eq(rowOf("top", 1).title, "时钟")
Assert.eq(rowOf("top", 2).title, "章节")
Assert.is_false(trail(rowOf("top", 1))[3].enabled)
Assert.is_true(trail(rowOf("top", 2))[3].enabled)

-- 设置图标推进组件页；启用、对齐在子页，不在主列表。
overlay_pushes = {}
trail(rowOf("top", 2))[1].callback()
Assert.len(overlay_pushes, 1)
Assert.eq(overlay_pushes[1].desktop, desktop)
Assert.eq(overlay_pushes[1].spec.title, "章节")
local chapter_rows = overlay_pushes[1].spec.sections()[1].rows
Assert.eq(chapter_rows[1](600).title, "启用")
Assert.is_true(chapter_rows[1](600).status_on)
Assert.eq(chapter_rows[2](600).title, "对齐")
Assert.eq(chapter_rows[2](600).current, "left")
chapter_rows[2](600).on_select("center")
Assert.eq(layouts.top[2].align, "center")

local bottom = ReaderBar:page(desktop, "bottom")
Assert.eq(bottom.sections[1].rows[1](600).title, "替代系统底栏")
Assert.eq(bottom.sections[1].rows[2](600).title, "开启底栏")
Assert.is_false(bottom.sections[1].rows[2](600).status_on)
Assert.len(bottom.sections[1].rows, 7, "底栏公共显示项含布局，不含组件专属设置")
Assert.eq(bottom.sections[1].rows[3](600).title, "布局")
Assert.eq(bottom.sections[1].rows[3](600).current, "single")
Assert.eq(bottom.sections[1].rows[3](600).items[1].text, "单栏")
Assert.eq(bottom.sections[1].rows[3](600).items[2].text, "双栏")
bottom.sections[1].rows[3](600).on_select("double")
Assert.is_true(stacked_on, "选双栏立即落盘")
Assert.eq(ReaderBar:page(desktop, "bottom").sections[1].rows[3](600).current, "double")
ReaderBar:page(desktop, "bottom").sections[1].rows[3](600).on_select("single")
Assert.is_false(stacked_on)
Assert.eq(page.sections[1].rows[3](600).title, "组件图标", "顶栏没有栏数设置")
Assert.eq(bottom.sections[1].rows[4](600).title, "组件图标")
Assert.eq(bottom.sections[1].rows[5](600).title, "分割线")
Assert.eq(bottom.sections[1].rows[6](600).title, "文字大小")
Assert.eq(bottom.sections[1].rows[7](600).title, "边距")
Assert.eq(bottom.sections[2].rows[1](600).title, "进度")
Assert.eq(bottom.sections[2].rows[2](600).title, "进度条")
Assert.eq(bottom.sections[2].rows[3](600).title, "书名")

-- 开双栏后主列表按上下行分段；切回单栏行归属还在。
bottom.sections[1].rows[3](600).on_select("double")
local dual_page = ReaderBar:page(desktop, "bottom")
Assert.eq(dual_page.sections[2].title, "上行")
Assert.eq(dual_page.sections[3].title, "下行")
Assert.eq(dual_page.sections[4].title, "未启用")
Assert.eq(dual_page.sections[2].rows[1](600).title, "进度")
Assert.eq(dual_page.sections[2].rows[2](600).title, "进度条")
Assert.eq(dual_page.sections[4].rows[1](600).title, "书名")
dual_page.sections[1].rows[3](600).on_select("single")

-- 两位小数与所在行都在进度组件页。
local percent_page = ReaderBar.itemPage(desktop, "bottom", catalogs.bottom[1])
local percent_rows = percent_page.sections()[1].rows
Assert.eq(percent_rows[1](600).title, "启用")
Assert.eq(percent_rows[3](600).title, "所在行")
Assert.eq(percent_rows[3](600).current, "up")
percent_rows[3](600).on_select("down")
Assert.eq(layouts.bottom[1].row, "down")
Assert.eq(percent_rows[4](600).title, "总进度显示两位小数")
Assert.is_false(percent_rows[4](600).status_on)
percent_rows[4](600).callback()
Assert.is_true(percent_decimals)
Assert.is_true(percent_page.sections()[1].rows[4](600).status_on)

-- 进度条粗细在进度条组件页；所在行在粗细前面。
local bar_page = ReaderBar.itemPage(desktop, "bottom", catalogs.bottom[2])
local bar_rows = bar_page.sections()[1].rows
Assert.eq(bar_rows[3](600).title, "所在行")
Assert.eq(bar_rows[4](600).title, "进度条粗细")
Assert.is_true(bar_rows[4](600).status:find("跟随主题", 1, true) ~= nil)
bar_rows[4](600).callback()
spins[#spins].callback(6)
Assert.eq(thickness, 6)
Assert.eq(bar_page.sections()[1].rows[4](600).status, "6")

-- 未启用组件只有启用项；打开后出现对齐，原顺序表末追加且不丢已有项。
local title_page = ReaderBar.itemPage(desktop, "bottom", catalogs.bottom[3])
Assert.len(title_page.sections()[1].rows, 1)
Assert.eq(title_page.sections()[1].rows[1](600).title, "启用")
Assert.is_false(title_page.sections()[1].rows[1](600).status_on)
title_page.sections()[1].rows[1](600).callback()
Assert.eq(layouts.bottom[3].id, "title")
Assert.eq(layouts.bottom[1].id, "percent", "启用新项不打乱已有顺序")
local title_rows = title_page.sections()[1].rows
Assert.len(title_rows, 3)
Assert.eq(title_rows[2](600).title, "对齐")
Assert.eq(title_rows[3](600).title, "所在行")

-- 底栏文字大小写回开着书的 KOReader 状态栏并立即重排。
local footer_calls = {}
local footer = { settings = { text_font_size = 14 },
    updateFooterFont = function() footer_calls[#footer_calls + 1] = "font" end,
    refreshFooter = function() footer_calls[#footer_calls + 1] = "refresh" end }
ReaderUIStub.instance = { document = {}, dialog = {}, view = { footer = footer } }
bottom.sections[1].rows[6](600).callback()
spins[#spins].callback(18)
Assert.eq(font.bottom, 18)
Assert.eq(footer.settings.text_font_size, 18)
Assert.eq(table.concat(footer_calls, ","), "font,refresh")
Assert.eq(bottom.sections[1].rows[6](600).status, "18")
ReaderUIStub.instance = nil

-- 关书时 closeDocument 已清 document、instance 尚未清：不得把半死的 ReaderUI 交给底栏
-- （否则 ReaderFooter:genFooterText 索引 ui.document 崩溃）；偏好仍照常写入
ReaderUIStub.instance = { document = nil, dialog = {} }
bottom.sections[1].rows[2](600).callback()
Assert.len(bottom_calls, 1)
Assert.is_true(bottom_calls[1].enabled)
Assert.is_nil(bottom_calls[1].ui)

local live = { document = {}, dialog = {} }
ReaderUIStub.instance = live
bottom.sections[1].rows[2](600).callback()
Assert.eq(bottom_calls[2].ui, live)

return true
