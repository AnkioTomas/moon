--[[--
首页垂直布局：组件声明最小/理想/最大高度，页面统一分配。

@module koplugin.book.ui.desktop.home.layout
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Base = require("ui.desktop.home.components.base")

local Layout = {}

---@param value number|nil
---@param fallback number
---@return number
local function height(value, fallback)
    return math.max(1, math.floor(tonumber(value) or fallback))
end

--- 把剩余高度按权重扩到指定上限。
---@param items table[]
---@param heights number[]
---@param remaining number
---@param target string
---@param weighted boolean
---@return number
local function grow(items, heights, remaining, target, weighted)
    while remaining > 0 do
        local total_weight = 0
        for i, item in ipairs(items) do
            if item.step == 0 and heights[i] < item[target] then
                total_weight = total_weight + (weighted and item.grow or 1)
            end
        end
        if total_weight <= 0 then break end

        local before = remaining
        for i, item in ipairs(items) do
            local weight = weighted and item.grow or 1
            local capacity = item[target] - heights[i]
            if item.step == 0 and capacity > 0 and weight > 0 and remaining > 0 then
                local share = math.max(1, math.floor(before * weight / total_weight))
                local add = math.min(capacity, share, remaining)
                heights[i] = heights[i] + add
                remaining = remaining - add
            end
        end
        if remaining == before then break end
    end
    return remaining
end

--- 离散组件只能按完整步长增长，避免书架拿到画不出整行的高度。
---@param items table[]
---@param heights number[]
---@param remaining number
---@param target string
---@return number
local function growStepped(items, heights, remaining, target)
    for i, item in ipairs(items) do
        while item.step > 0
            and heights[i] + item.step <= item[target]
            and remaining >= item.step
        do
            heights[i] = heights[i] + item.step
            remaining = remaining - item.step
        end
    end
    return remaining
end

--- 按顺序选出最小高度放得下的组件，再分配理想值和最大值。
---@param ranges table[]
---@param available number
---@param gap number
---@return table[] selected
---@return number[] heights
---@return number unused
function Layout.allocate(ranges, available, gap)
    available = math.max(0, math.floor(tonumber(available) or 0))
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    local selected = {}
    local minimum = 0
    for _, raw in ipairs(ranges) do
        local min_h = height(raw.min, 1)
        local preferred = math.max(min_h, height(raw.preferred, min_h))
        local max_h = math.max(preferred, height(raw.max, preferred))
        local next_min = minimum + (#selected > 0 and gap or 0) + min_h
        if next_min > available then break end
        selected[#selected + 1] = {
            comp = raw.comp,
            id = raw.id,
            min = min_h,
            preferred = preferred,
            max = max_h,
            grow = math.max(0, tonumber(raw.grow) or 1),
            step = math.max(0, math.floor(tonumber(raw.step) or 0)),
        }
        minimum = next_min
    end

    local heights = {}
    for i, item in ipairs(selected) do heights[i] = item.min end
    local remaining = available - minimum
    -- 默认书架优先拿到完整的第二行；凑不齐时一像素也不浪费给它。
    remaining = growStepped(selected, heights, remaining, "preferred")
    remaining = grow(selected, heights, remaining, "preferred", false)
    remaining = grow(selected, heights, remaining, "max", true)
    remaining = growStepped(selected, heights, remaining, "max")
    return selected, heights, remaining
end

--- 组装首页内容区。
---@param ctx table
---@param state table
---@return table
function Layout.build(ctx, state)
    local w = ctx.width
    local h = ctx.height
    local layout_ids = Base.enabledLayout()
    local gap = UI.sz(8)
    local kids = { align = "left" }
    local used = 0
    if ctx.desktop then
        ctx.desktop._home_clock_refresh = nil
        ctx.desktop._home_clock_region = nil
    end

    local ranges = {}
    for _, id in ipairs(layout_ids) do
        local comp = Base.find(id)
        if comp then
            local range = comp.heightRange(ctx, state, { width = w, height = h })
            range.comp = comp
            range.id = id
            ranges[#ranges + 1] = range
        end
    end

    local selected, heights, unused = Layout.allocate(ranges, h, gap)
    for i, item in ipairs(selected) do
        if i > 1 then
            table.insert(kids, VerticalSpan:new{ width = gap })
            used = used + gap
        end
        local allocated = heights[i]
        local part = item.comp.build(ctx, state, {
            width = w,
            height = allocated,
            budget = allocated,
            desktop = ctx.desktop,
        })
        table.insert(kids, part.widget)
        if part.refresh and ctx.desktop then
            ctx.desktop._home_clock_refresh = part.refresh
            ctx.desktop._home_clock_region = Geom:new{
                x = 0,
                y = used,
                w = w,
                h = allocated,
            }
        end
        used = used + allocated
    end
    if unused > 0 then
        table.insert(kids, VerticalSpan:new{ width = unused })
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        -- FrameContainer 的背景尺寸取 width/height，不取 dimen；组件内容不足一屏时
        -- 不显式填满会留下旧页面像素，切回首页就会出现半屏白/残影。
        width = w,
        height = h,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new(kids),
    }
end

return Layout
