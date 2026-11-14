--[[--
底栏组件行真实主题控件布局：图标、名称、设置、上移、下移的几何，
对照侧栏页面顺序的 36px ghost 按钮和 4px 间距。仅凭断言不能宣称美观，
本文件把实测坐标写到 test/moon-bar-settings-row-metrics.txt 供出图核对。
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["l10n"] = function() return { apply = function() end } end

local Kit = require("support.widget_stubs")
Kit.install()

package.preload["desktop.pages.setting.overlay"] = function()
    return { push = function() end }
end
package.preload["apps/reader/readerui"] = function()
    return { instance = nil }
end
package.preload["features.bars"] = function()
    return {
        topBarPreference = function() return true end,
        bottomBarPreference = function() return true end,
        setTopBarPreference = function() end,
        setBottomBarPreference = function() end,
        syncTopMargin = function() end,
        syncBottomHeight = function() end,
    }
end
package.preload["features.bars.preview"] = function()
    return {
        build = function(width, which) return { kind = "preview", width = width, which = which } end,
        footerSettings = function() return nil, nil end,
    }
end

local layouts = {
    top = {
        { id = "chapter", align = "left" },
        { id = "clock", align = "right" },
    },
}
local catalogs = {
    top = {
        { id = "chapter", label = "章节", icon = "menu_book" },
        { id = "clock", label = "时钟", icon = "schedule" },
        { id = "battery", label = "电量", icon = "battery_full" },
    },
}

package.preload["features.bars.layout"] = function()
    return {
        FONT_MIN = 8, FONT_MAX = 36, TOP_HEIGHT_MIN = 0, TOP_HEIGHT_MAX = 60,
        BAR_THICKNESS_MIN = 1, BAR_THICKNESS_MAX = 24,
        progressThickness = function() end,
        themeProgressThickness = function() return 8 end,
        fontSize = function() return 14 end,
        topFontCustom = function() return false end,
        setFontSize = function() end,
        topHeight = function() return 12 end,
        topMargin = function() return 0 end,
        bottomMargin = function() return 1 end,
        TOP_MARGIN_MIN = 0, TOP_MARGIN_MAX = 60, BOTTOM_MARGIN_MIN = 0, BOTTOM_MARGIN_MAX = 49,
        setTopHeight = function() end,
        icons = function() return true end,
        divider = function() return false end,
        setDivider = function() end,
        percentDecimals = function() return false end,
        setPercentDecimals = function() end,
        setIcons = function() end,
        replace = function() return true end,
        setReplace = function() end,
        get = function(which) return layouts[which] end,
        slot = function(which, id)
            for i = 1, #layouts[which] do
                if layouts[which][i].id == id then
                    return i, layouts[which][i].align
                end
            end
        end,
        orderedCatalog = function(which)
            local by_id, out = {}, {}
            for i = 1, #catalogs[which] do by_id[catalogs[which][i].id] = catalogs[which][i] end
            for i = 1, #layouts[which] do
                local item = by_id[layouts[which][i].id]
                if item then
                    out[#out + 1] = item
                    by_id[layouts[which][i].id] = nil
                end
            end
            for i = 1, #catalogs[which] do
                if by_id[catalogs[which][i].id] then out[#out + 1] = by_id[catalogs[which][i].id] end
            end
            return out
        end,
        toggle = function() end,
        move = function() end,
        setAlign = function() end,
    }
end

package.loaded["features.bars.page"] = nil
package.loaded["ui.themes"] = nil
local Theme = require("ui.themes")
local ReaderBar = require("features.bars.page")
local desktop = { updateView = function() end, settings = {} }
local page = ReaderBar:page(desktop, "top")

local TextWidget = require("ui/widget/textwidget")
local painted = {}
local orig_paint = TextWidget.paintTo
TextWidget.paintTo = function(self, bb, px, py)
    painted[#painted + 1] = { text = self.text, x = px, y = py, w = self:getSize().w, h = self:getSize().h }
    if orig_paint then orig_paint(self, bb, px, py) end
end

local WIDTH = 600
local function paintRow(index, y)
    local row = page.sections[2].rows[index](WIDTH)
    row:paintTo(Kit.canvas(), 0, y)
    return row
end

local r1 = paintRow(1, 0)
local r2 = paintRow(2, 80)
local r3 = paintRow(3, 160)

local function firstPainted(text, min_y, max_y)
    for i = 1, #painted do
        local p = painted[i]
        if p.text == text and p.y >= min_y and p.y < max_y then
            return p
        end
    end
end

local function metrics(row, y)
    local buttons = Kit.buttons(row)
    Assert.len(buttons, 3, "右侧只有设置 / 上 / 下三个按钮")
    Assert.eq(buttons[1].icon, "settings")
    Assert.eq(buttons[2].icon, "arrow_upward")
    Assert.eq(buttons[3].icon, "arrow_downward")
    local size = Theme.px(36)
    local gap = Theme.px(4)
    for i = 1, 3 do
        Assert.eq(buttons[i].variant, "ghost")
        Assert.eq(buttons[i].dimen.w, size, "按钮宽与侧栏页面顺序一致")
        Assert.eq(buttons[i].dimen.h, size, "按钮高与侧栏页面顺序一致")
    end
    Assert.eq(buttons[2].dimen.x, buttons[1].dimen.x + size + gap, "设置与上移间隔 4px")
    Assert.eq(buttons[3].dimen.x, buttons[2].dimen.x + size + gap, "上移与下移间隔 4px")
    local title = firstPainted(row.row_title, y, y + 80)
    Assert.not_nil(title, "行里画了组件名")
    -- 行图标是菜单/时钟/电量，不是右侧按钮图标。
    ---@type table|nil
    local row_icon
    for i = 1, #painted do
        local p = painted[i]
        if p.y >= y and p.y < y + 80 and p.text ~= row.row_title
            and p.text ~= "settings" and p.text ~= "arrow_upward" and p.text ~= "arrow_downward"
            and p.text ~= "chevron_right" then
            row_icon = p
            break
        end
    end
    Assert.not_nil(row_icon, "行左侧画了组件图标")
    local chevrons = firstPainted("chevron_right", y, y + 80)
    Assert.is_nil(chevrons, "组件行不画右箭头，右侧让给排序按钮")
    return {
        title = row.row_title,
        title_x = title.x,
        title_w = title.w,
        icon_x = row_icon.x,
        icon_w = row_icon.w,
        settings = buttons[1].dimen,
        up = buttons[2].dimen,
        down = buttons[3].dimen,
        up_enabled = buttons[2].enabled,
        down_enabled = buttons[3].enabled,
        row_h = row:getSize().h,
    }
end

local m1 = metrics(r1, 0)
local m2 = metrics(r2, 80)
local m3 = metrics(r3, 160)

Assert.eq(m1.title, "章节")
Assert.eq(m2.title, "时钟")
Assert.eq(m3.title, "电量")
Assert.is_false(m1.up_enabled, "第一项上移禁用")
Assert.is_true(m1.down_enabled)
Assert.is_true(m2.up_enabled)
Assert.is_false(m2.down_enabled, "布局末项下移禁用")
Assert.is_false(m3.up_enabled, "未启用上移禁用")
Assert.is_false(m3.down_enabled, "未启用下移禁用")

-- 组件名在图标右侧、设置按钮左侧，不和按钮重叠。
-- 图标字体在桩里按 ASCII 名计宽，不能用 glyph 宽度判断是否重叠；
-- 以主题令牌算出来的图标列验证组件名起点，与普通设置行同一套边距。
local th = Theme.current()
local pad = Theme.px(th.space.md)
local icon_col = Theme.px(th.control.icon) + Theme.px(th.space.sm)
Assert.eq(m1.title_x, pad + icon_col, "组件名从图标列右侧开始，与普通设置行一致")
Assert.is_true(m1.title_x + m1.title_w <= m1.settings.x, "标题不压到设置按钮")
Assert.is_true(m1.settings.x < m1.up.x)
Assert.is_true(m1.up.x < m1.down.x)
Assert.is_true(m1.down.x + m1.down.w <= WIDTH, "下移按钮不溢出行宽")
-- 下移贴右侧内边距（主题 md），允许 1px 舍入。
local right_pad = Theme.px(Theme.current().space.md)
Assert.is_true(math.abs((m1.down.x + m1.down.w) - (WIDTH - right_pad)) <= 1,
    "下移按钮贴右侧内边距，与普通设置行对齐")

local function dump(name, m)
    return string.format(
        "%s title=%s icon_x=%s title_x=%s title_w=%s settings=%s,%s %sx%s up=%s,%s down=%s,%s up_on=%s down_on=%s row_h=%s",
        name, m.title, tostring(m.icon_x), tostring(m.title_x), tostring(m.title_w),
        tostring(m.settings.x), tostring(m.settings.y), tostring(m.settings.w), tostring(m.settings.h),
        tostring(m.up.x), tostring(m.up.y), tostring(m.down.x), tostring(m.down.y),
        tostring(m.up_enabled), tostring(m.down_enabled), tostring(m.row_h)
    )
end

local home = Config.dir()
os.execute("mkdir -p " .. string.format("%q", home))
local path = home .. "/moon-bar-settings-row-metrics.txt"
local f = io.open(path, "w")
Assert.not_nil(f, "写得出布局度量文件")
f:write("width=" .. WIDTH .. " px36=" .. Theme.px(36) .. " gap=" .. Theme.px(4)
    .. " pad=" .. right_pad .. "\n")
f:write(dump("row1", m1) .. "\n")
f:write(dump("row2", m2) .. "\n")
f:write(dump("row3", m3) .. "\n")
f:close()

return true
