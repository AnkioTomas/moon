--[[--
首页垂直布局：按设置顺序堆叠组件，预算不足则裁剪。

recent_list 布局角色：
  footer_full — 唯一组件，吃满剩余高度，分页条钉底
  footer_tail — 纯列表模式且末位，同上
  inline      — 普通堆叠，网格高度封顶

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

---@param layout_ids string[]
---@param index number
---@param id string
---@return string|nil "footer_full"|"footer_tail"|"inline"
local function recentListMode(layout_ids, index, id)
    if id ~= "recent_list" then return nil end
    if layout_ids[1] == "recent_list" and #layout_ids == 1 then
        return "footer_full"
    end
    local list_only = MoonSettings.get("home").home_recent_list_mode == "list_only"
    if list_only and index == #layout_ids then
        return "footer_tail"
    end
    return "inline"
end

---@param layout_ids string[]
---@return boolean
local function footerPager(layout_ids)
    if layout_ids[1] == "recent_list" and #layout_ids == 1 then
        return true
    end
    local list_only = MoonSettings.get("home").home_recent_list_mode == "list_only"
    return list_only and layout_ids[#layout_ids] == "recent_list"
end

--- 组装首页内容区。
---@param ctx table
---@param state table
---@return table
function Layout.build(ctx, state)
    local w = ctx.width
    local h = ctx.height
    local layout_ids = Base.enabledLayout()
    local pin_pager = footerPager(layout_ids)
    local band_h = pin_pager and Pager.bandH() or 0
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
                local recent_mode = recentListMode(layout_ids, i, id)
                local opts = {
                    width = w,
                    budget = remaining,
                    recent_mode = recent_mode,
                    desktop = ctx.desktop,
                }
                local part = comp.build(ctx, state, opts)
                local ph = part.height or (part.widget and part.widget:getSize().h) or 0
                local fill_footer = recent_mode == "footer_full" or recent_mode == "footer_tail"
                if used + comp_gap + ph > budget then
                    if fill_footer then
                        ph = math.max(1, budget - used - comp_gap)
                    else
                        break
                    end
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

    if pin_pager and pager then
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
