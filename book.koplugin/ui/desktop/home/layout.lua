--[[--
首页垂直布局：按设置顺序堆叠组件，预算不足则裁剪。

@module koplugin.book.ui.desktop.home.layout
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Pager = require("ui.components.pager")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local MoonSettings = require("utils.settings")
local Base = require("ui.desktop.home.components.base")

local Layout = {}

--- 组装首页内容区。
---@param ctx table
---@param state table
---@return table
function Layout.build(ctx, state)
    local w = ctx.width
    local h = ctx.height
    local layout_ids = Base.enabledLayout()
    local sole_recent = layout_ids[1] == "recent_list" and #layout_ids == 1
    local list_only = MoonSettings.get("home").home_recent_list_mode == "list_only"
    local recent_tail = list_only and layout_ids[#layout_ids] == "recent_list"
    local footer_recent = sole_recent or recent_tail
    local band_h = footer_recent and Pager.bandH() or 0
    local budget = math.max(1, h - band_h)
    local gap = UI.sz(8)
    local kids = { align = "left" }
    local used = 0
    local pager = nil

    for i, id in ipairs(layout_ids) do
        local comp = Base.find(id)
        if comp then
            local comp_gap = i > 1 and gap or 0
            local remaining = budget - used - comp_gap
            if remaining > 0 then
                local opts = {
                    width = w,
                    budget = remaining,
                    sole = sole_recent and id == "recent_list",
                    consume_remaining = footer_recent and id == "recent_list",
                    list_only = list_only and id == "recent_list",
                    desktop = ctx.desktop,
                }
                local part = comp.build(ctx, state, opts)
                local ph = part.height or (part.widget and part.widget:getSize().h) or 0
                if comp_gap > 0 and used + comp_gap + ph > budget then break end
                if comp_gap == 0 and ph > budget then
                    ph = budget
                end
                if comp_gap > 0 then
                    table.insert(kids, VerticalSpan:new{ width = comp_gap })
                    used = used + comp_gap
                end
                table.insert(kids, part.widget)
                used = used + ph
                if part.pager then pager = part.pager end
            end
        end
    end

    if footer_recent and pager then
        local filler = math.max(0, budget - used)
        if filler > 0 then
            table.insert(kids, VerticalSpan:new{ width = filler })
        end
        table.insert(kids, Pager.band(w, pager.page, pager.pages, pager.handlers))
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new(kids),
    }
end

return Layout
