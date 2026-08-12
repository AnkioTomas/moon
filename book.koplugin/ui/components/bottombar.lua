--[[--
Desktop 底栏 Tab：首页 / 图书馆 / [书城] / 统计 / 设置
  书城仅当 source.capabilities.store 时插入

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
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local UI = require("ui.components.bookui")

local BottomBar = {}

function BottomBar.tabs(source)
    local tabs = {
        { id = "home", text = _("首页"), icon = "home.svg" },
        { id = "library", text = _("图书馆"), icon = "library.svg" },
    }
    local caps = source and source.capabilities and source:capabilities() or {}
    if caps.store then
        table.insert(tabs, { id = "store", text = _("书城"), icon = "store.svg" })
    end
    table.insert(tabs, { id = "stats", text = _("统计"), icon = "stats.svg" })
    table.insert(tabs, { id = "settings", text = _("设置"), icon = "settings.svg" })
    return tabs
end

--- @param desktop table Desktop 实例（读 tab / source）
function BottomBar.build(desktop)
    local tabs = BottomBar.tabs(desktop.source)
    desktop._tabs = tabs
    local sw = Screen:getWidth()
    local bh = UI.barH()
    local icon_sz = UI.iconSz()
    local icon_dir = UI.iconDir()
    local cell_w = math.floor(sw / #tabs)
    local underline_h = UI.sz(2)
    local row = HorizontalGroup:new{ align = "center" }
    for _, tab in ipairs(tabs) do
        local active = desktop.tab == tab.id
        local icon
        local ok, img = pcall(function()
            return ImageWidget:new{
                file = icon_dir .. tab.icon,
                width = icon_sz,
                height = icon_sz,
                alpha = true,
            }
        end)
        if ok and img then
            icon = img
        else
            icon = TextWidget:new{
                text = "•",
                face = UI.face("cfont", 18),
                fgcolor = active and Blitbuffer.COLOR_BLACK or UI.dim(),
            }
        end
        local label = TextWidget:new{
            text = tab.text,
            face = UI.face(active and "cfont" or "xx_smallinfofont", active and 13 or 12),
            fgcolor = active and Blitbuffer.COLOR_BLACK or UI.muted(),
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
            LineWidget:new{
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = cell_w, h = underline_h },
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
