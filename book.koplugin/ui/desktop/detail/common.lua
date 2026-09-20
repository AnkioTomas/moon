--[[-- 书籍详情子模块。 @module ui.desktop.detail --]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local BookInfo = require("ui.components.bookinfo")
local Icon = require("ui.components.icon")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local SourceCapabilities = require("source.base").SourceCapabilities


local M = {}

function M.storeKind(book, _source, _origin)
    if type(book) == "table" and book.source_id == "zlib" then
        return "zlib"
    end
    return nil
end

--- 书籍属主源：身份匹配当前源则复用，否则按 source_id 解析。
---@param book table|nil 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return table|nil
function M.bookOwnerSource(book, fallback_source)
    if type(book) ~= "table" or type(book.source_id) ~= "string" then
        return fallback_source
    end
    return require("source.registry").resolve(book.source_id) or fallback_source
end

--- 按书籍属主源判断是否可刮削（不用当前活跃源冒充）。
---@param book table|nil 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return boolean
function M.bookSupportsScrape(book, fallback_source)
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return false
    end
    return SourceCapabilities.supportsScrape(M.bookOwnerSource(book, fallback_source))
end

--- 按书籍属主源判断是否可编辑元信息。
---@param book table|nil 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return boolean
function M.bookSupportsEdit(book, fallback_source)
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return false
    end
    return SourceCapabilities.supportsEdit(M.bookOwnerSource(book, fallback_source))
end

--- 小节标题（书城书的简介用）。
---@param text string 需要展示的文字
---@param width number 目标宽度，单位像素
---@return table
function M.sectionTitle(text, width)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = UI.sz(30) },
        TextWidget:new{
            text = text,
            face = UI.face("cfont", 15),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
end

--- 动作 chip：等宽描边按钮，Material 图标 + 文案（不加粗），整颗可点。
---@param w number 可用宽度，单位像素
---@param h number 可用高度，单位像素
---@param icon string Material Icons 原名
---@param text string 需要展示的文字
---@param on_tap fun() 点击命中区域时执行的回调
---@param direction string|nil "row"（默认）或 "column"
---@return table
function M.actionChip(w, h, icon, text, on_tap, direction)
    direction = direction or "row"
    local column = direction == "column"
    local tap = BookInfo.tappable(w, h, on_tap)
    tap[1] = Surface.build{ child = Icon.label{
                name = icon,
                text = text,
                direction = direction,
                size = column and 20 or 18,
                font_size = column and 11 or 14,
                gap = column and UI.sz(2) or UI.sz(6),
                max_width = w - UI.sz(8),
            }, options = {
        width = w,
        height = h,
        shadow = false,
    }, kind = "pill" }
    return tap
end

--- 等宽 chip 行。
---@param width number 行宽，单位像素
---@param height number 按钮高度，单位像素
---@param chips table[] { icon, text, fn }
---@param direction string|nil "row" 或 "column"
---@return table
function M.chipRow(width, height, chips, direction)
    local gap = UI.sz(8)
    local n = #chips
    local cell_w = n > 0 and math.floor((width - gap * (n - 1)) / n) or width
    local row = HorizontalGroup:new{ align = "center" }
    for i, chip in ipairs(chips) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, M.actionChip(cell_w, height, chip.icon, chip.text, chip.fn, direction))
    end
    return row
end

--- KPI 卡片：描边白底，上值下标签。
---@param w number 可用宽度，单位像素
---@param value string 当前设置项的值
---@param label string 展示给用户的标签文字
---@return table, number 卡片 widget 与其高度
function M.kpiCard(w, value, label)
    local pad = UI.sz(10)
    local inner_w = math.max(1, w - pad * 2)
    local value_w = TextWidget:new{
        text = value,
        face = UI.face("cfont", 16),
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_w = TextWidget:new{
        text = label,
        face = UI.face("xx_smallinfofont", 11),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local h = pad * 2 + value_w:getSize().h + UI.sz(4) + label_w:getSize().h
    local card = Surface.build{ child = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = h - pad * 2 },
            VerticalGroup:new{
                align = "center",
                value_w,
                VerticalSpan:new{ width = UI.sz(4) },
                label_w,
            },
        }, options = {
        width = w,
        height = h,
        padding = pad,
        shadow = true,
    }, kind = "card" }
    return card, h
end


return M
