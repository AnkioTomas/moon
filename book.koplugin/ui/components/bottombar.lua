--[[--
Desktop 底栏 Tab：首页 / 图书馆 / [书城] / 统计 / 设置
  书城仅当 source.capabilities.store 时插入

选中态（墨水屏优先对比）：
  图标不 dim、标签加粗加大、底部短粗指示条
未选中：图标 dim、标签浅灰缩小

@module koplugin.book.ui.components.bottombar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")
local Screen = Device.screen

local UI = require("ui.components.bookui")
local Image = require("ui.components.image")

local BottomBar = {}

--- 按数据源能力生成底栏 Tab 列表。
---@param source table|nil
---@return table
function BottomBar.tabs(source)
    local tabs = {
        { id = "home", text = _("首页"), icon = "home.svg" },
        { id = "library", text = _("图书馆"), icon = "library.svg" },
    }
    local caps = source and source.capabilities and source:capabilities() or {}
    if caps.store then
        table.insert(tabs, { id = "store", text = _("书城"), icon = "store.svg" })
    end
    if caps.insight then
        table.insert(tabs, { id = "stats", text = _("统计"), icon = "stats.svg" })
    end
    table.insert(tabs, { id = "settings", text = _("设置"), icon = "settings.svg" })
    return tabs
end

--- 底栏 Tab 图标；失败回退圆点文字。
---@param name string
---@param sz number
---@param active boolean
---@return table
local function tabIcon(name, sz, active)
    local path = Image.resolve(name)
    if path then
        local ok, img = pcall(function()
            return ImageWidget:new{
                file = path,
                width = sz,
                height = sz,
                alpha = true,
                dim = not active,
            }
        end)
        if ok and img then
            return img
        end
    end
    return TextWidget:new{
        text = "•",
        face = UI.face("cfont", active and 18 or 16),
        fgcolor = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_6,
    }
end

--- 构建底栏 widget。
---@param desktop table Desktop 实例（读 tab / source）
---@return table
function BottomBar.build(desktop)
    local tabs = BottomBar.tabs(desktop.source)
    desktop._tabs = tabs
    local sw = Screen:getWidth()
    local bh = UI.barH()
    local icon_sz = UI.iconSz()
    local cell_w = math.floor(sw / #tabs)
    local underline_h = UI.sz(3)
    -- 选中指示条：短粗，避免通栏细线「像分割线」
    local indicator_w = math.min(cell_w - UI.sz(20), math.max(UI.sz(28), icon_sz + UI.sz(12)))
    local row = HorizontalGroup:new{ align = "center" }
    for _, tab in ipairs(tabs) do
        local active = desktop.tab == tab.id
        local icon = tabIcon(tab.icon, icon_sz, active)
        local label = TextWidget:new{
            text = tab.text,
            face = UI.face(active and "cfont" or "xx_smallinfofont", active and 14 or 11),
            fgcolor = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_6,
        }
        local content_h = math.max(1, bh - underline_h)
        local cell = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = content_h },
                VerticalGroup:new{
                    align = "center",
                    VerticalSpan:new{ width = UI.sz(4) },
                    icon,
                    VerticalSpan:new{ width = UI.sz(2) },
                    label,
                },
            },
            CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = underline_h },
                LineWidget:new{
                    background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    dimen = Geom:new{
                        w = active and indicator_w or 1,
                        h = underline_h,
                    },
                },
            },
        }
        table.insert(row, cell)
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = bh },
        VerticalGroup:new{
            align = "left",
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = sw, h = UI.line() },
            },
            row,
        },
    }
end

return BottomBar
