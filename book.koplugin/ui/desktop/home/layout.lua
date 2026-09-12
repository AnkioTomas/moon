--[[--
首页垂直布局：按用户钉页组装；高度 default / 自定义 / fill。

@module koplugin.book.ui.desktop.home.layout
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Registry = require("ui.desktop.home.registry")
local Widgets = require("ui.desktop.home.widgets")

---@class BookHomeHeightRange
---@field min number
---@field preferred number
---@field max number
---@field grow number|nil
---@field step number|nil

---@class BookHomeBuildOpts
---@field width number
---@field height number
---@field budget number|nil
---@field desktop BookDesktop|nil
---@field y number|nil

---@class BookHomeLayout
local Layout = {}
Layout.__index = Layout

--- 创建独立的首页布局计算对象，不读取或修改组件状态。
---@return BookHomeLayout
function Layout.new()
    return setmetatable({}, Layout)
end

--- 把输入高度规范化为至少一个像素的整数，缺省使用回退值。
---@param value number|nil 当前设置项的值
---@param fallback number 输入无效时采用的回退值
---@return number
local function height(value, fallback)
    return math.max(1, math.floor(tonumber(value) or fallback))
end

--- 把剩余高度按权重扩到指定上限。
---@param items table[] 按布局顺序排列的项目
---@param heights number[] 与项目对应的当前高度数组；分配过程中原地更新
---@param remaining number 尚未分配的高度，单位像素
---@param target string 本次高度分配使用的目标字段名
---@param weighted boolean 是否按组件 grow 权重分配剩余高度
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

--- 离散组件只能按完整步长增长。
---@param items table[] 按布局顺序排列的项目
---@param heights number[] 与项目对应的当前高度数组；分配过程中原地更新
---@param remaining number 尚未分配的高度，单位像素
---@param target string 本次高度分配使用的目标字段名
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

--- 规范化组件高度约束，确保最小值、首选值、最大值和增长步长一致。
---@param raw BookHomeHeightRange 尚未规范化的接口数据或布局约束
---@return table
local function normalizeRange(raw)
    local min_h = height(raw.min, 1)
    local preferred = math.max(min_h, height(raw.preferred, min_h))
    local max_h = math.max(preferred, height(raw.max, preferred))
    local step = math.max(0, math.floor(tonumber(raw.step) or 0))
    return {
        comp = raw.comp,
        id = raw.id,
        placement = raw.placement,
        min = min_h,
        preferred = preferred,
        max = max_h,
        grow = math.max(0, tonumber(raw.grow) or 1),
        step = step,
        mode = raw.placement and raw.placement.height or "default",
    }
end

--- 解析非 fill 的目标高度。
---@param item table 当前布局项目及其高度配置
---@return number
local function fixedTarget(item)
    local mode = item.mode
    if type(mode) == "number" then
        local h = math.max(item.min, math.min(item.max, math.floor(mode)))
        if item.step > 0 then
            local base = item.min
            local steps = math.floor((h - base) / item.step + 0.5)
            h = math.max(item.min, math.min(item.max, base + steps * item.step))
        end
        return h
    end
    return item.preferred
end

--- 钉页分配：先定 default/custom，剩余给 fill；超高则整体压回 available。
---@param ranges BookHomeHeightRange[] 各组件的最小、首选和最大高度约束
---@param available number 当前布局可用的总高度，单位像素
---@param gap number 相邻项目间距，单位像素
---@return table[] selected
---@return number[] heights
---@return number unused
function Layout:allocate(ranges, available, gap)
    available = math.max(0, math.floor(tonumber(available) or 0))
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    local selected = {}
    for _, raw in ipairs(ranges) do
        selected[#selected + 1] = normalizeRange(raw)
    end
    if #selected == 0 then return selected, {}, available end

    local gaps = gap * (#selected - 1)
    local heights = {}
    local fill_idx = {}
    local fixed_sum = 0
    for i, item in ipairs(selected) do
        if item.mode == "fill" then
            heights[i] = item.min
            fill_idx[#fill_idx + 1] = i
        else
            heights[i] = fixedTarget(item)
            fixed_sum = fixed_sum + heights[i]
        end
    end

    local fill_min = 0
    for _, i in ipairs(fill_idx) do fill_min = fill_min + selected[i].min end
    local remaining = available - gaps - fixed_sum - fill_min

    if remaining < 0 then
        -- 超页：按比例压非 fill，再压 fill 的 min。
        local scale = (available - gaps) / math.max(1, fixed_sum + fill_min)
        for i, item in ipairs(selected) do
            if item.mode == "fill" then
                heights[i] = math.max(1, math.floor(item.min * scale))
            else
                heights[i] = math.max(1, math.floor(heights[i] * scale))
            end
        end
        local used = gaps
        for i = 1, #heights do used = used + heights[i] end
        return selected, heights, math.max(0, available - used)
    end

    -- fill 先拿到 min，再分剩余。
    if #fill_idx > 0 and remaining > 0 then
        local fill_items = {}
        local fill_heights = {}
        for j, i in ipairs(fill_idx) do
            local item = selected[i]
            fill_items[j] = {
                min = item.min,
                preferred = item.max,
                max = item.max,
                grow = item.grow > 0 and item.grow or 1,
                step = item.step,
            }
            fill_heights[j] = item.min
        end
        remaining = growStepped(fill_items, fill_heights, remaining, "preferred")
        remaining = grow(fill_items, fill_heights, remaining, "preferred", false)
        remaining = grow(fill_items, fill_heights, remaining, "max", true)
        remaining = growStepped(fill_items, fill_heights, remaining, "max")
        for j, i in ipairs(fill_idx) do
            heights[i] = fill_heights[j]
        end
    end

    local used = gaps
    for i = 1, #heights do used = used + heights[i] end
    return selected, heights, math.max(0, available - used)
end

--- 迁移用：按理想高度自动切页（旧行为）。
---@param ranges BookHomeHeightRange[] 各组件的最小、首选和最大高度约束
---@param available number 当前布局可用的总高度，单位像素
---@param gap number 相邻项目间距，单位像素
---@return table[] pages
function Layout:paginate(ranges, available, gap)
    available = math.max(0, math.floor(tonumber(available) or 0))
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    local pages, cur = {}, {}
    local used, slack = 0, 0

    --- 把当前累积的组件提交为一页，开始下一页的布局。
    ---@return nil
    local function flush()
        pages[#pages + 1] = cur
        cur, used, slack = {}, 0, 0
    end

    for _, raw in ipairs(ranges) do
        local min_h = height(raw.min, 1)
        local pref_h = math.max(min_h, height(raw.preferred, min_h))
        local grow_w = math.max(0, tonumber(raw.grow) or 1)
        local step = math.max(0, math.floor(tonumber(raw.step) or 0))
        local pad = #cur > 0 and gap or 0
        local need = pad + min_h
        if #cur > 0 and used + need > available then
            local short = used + need - available
            if slack >= short then
                used = used - short
                slack = slack - short
            else
                flush()
                pad = 0
            end
        end
        local take = pref_h
        if used + pad + pref_h > available then
            take = min_h
        end
        cur[#cur + 1] = raw
        used = used + pad + take
        if grow_w > 0 or step > 0 then
            slack = slack + (take - min_h)
        end
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    if #pages == 0 then pages[1] = {} end
    return pages
end

--- 组装一页内容。page 从 1 起；页边界由 home_widgets 钉死。
---@param ctx BookDesktopCtx 构建上下文，提供尺寸、数据源和桌面宿主
---@param components table<string, BookHomeComponent>
---@param page number|nil 当前页码，从 1 开始
---@param opts { wrap?: fun(widget, meta): table, body_height?: number }|nil
---@return table widget
---@return number page
---@return number pages
---@return table<string, boolean> visible
function Layout:build(ctx, components, page, opts)
    opts = opts or {}
    local w = ctx.width
    local h = ctx.height
    local body_h = math.max(1, math.floor(tonumber(opts.body_height) or h))
    local placements = Registry.widgets()
    local gap = UI.sz(8)
    local pages = Widgets.pageCount(placements)
    page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))

    local page_items = Widgets.onPage(placements, page)
    local ranges = {}
    for _, place in ipairs(page_items) do
        local comp = components[place.id]
        if comp then
            local range = comp:heightRange(ctx, { width = w, height = body_h })
            range.comp = comp
            range.id = place.id
            range.placement = place
            ranges[#ranges + 1] = range
        end
    end

    local selected, heights, unused = self:allocate(ranges, body_h, gap)
    local kids = { align = "left" }
    local used = 0
    local visible = {}
    for i, item in ipairs(selected) do
        visible[item.id] = true
        if i > 1 then
            table.insert(kids, VerticalSpan:new{ width = gap })
            used = used + gap
        end
        local allocated = heights[i]
        local part = item.comp:build(ctx, {
            width = w,
            height = allocated,
            budget = allocated,
            desktop = ctx.desktop,
            y = UI.topBarH() + used,
        })
        local widget = part
        if opts.wrap then
            widget = opts.wrap(widget, {
                id = item.id,
                height = allocated,
                width = w,
                placement = item.placement,
                range = {
                    min = item.min,
                    preferred = item.preferred,
                    max = item.max,
                    step = item.step,
                },
            })
        end
        table.insert(kids, widget)
        used = used + allocated
    end
    if unused > 0 then
        table.insert(kids, VerticalSpan:new{ width = unused })
    end

    local body = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = w,
        height = body_h,
        dimen = Geom:new{ w = w, h = body_h },
        VerticalGroup:new(kids),
    }
    return body, page, pages, visible
end

return Layout
