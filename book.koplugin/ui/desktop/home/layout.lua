--[[--
首页垂直布局：默认累加各组件内容高度，fill 吃页内剩余。

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

---@class BookHomeHeightSpec
---@field height number 内容自然高度
---@field fill boolean|nil 为真时从内容高度往上吃剩余，无上限

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

--- 读组件报的内容高度；兼容旧 min/preferred 字段。
---@param raw table
---@return number
local function specHeight(raw)
    local h = tonumber(raw.height) or tonumber(raw.preferred) or tonumber(raw.min)
    return math.max(1, math.floor(h or 1))
end

--- 把输入高度规范化为至少一个像素的整数。
---@param value number|nil
---@param fallback number
---@return number
local function height(value, fallback)
    return math.max(1, math.floor(tonumber(value) or fallback))
end

--- 放置模式 + 组件 fill：自定义像素锁死，fill 或组件声明则吃剩余。
---@param raw table
---@return table
local function normalize(raw)
    local mode = raw.placement and raw.placement.height or "default"
    local fill = false
    if type(mode) ~= "number" then
        fill = raw.fill == true or mode == "fill"
    end
    return {
        comp = raw.comp,
        id = raw.id,
        placement = raw.placement,
        height = specHeight(raw),
        fill = fill,
        mode = mode,
    }
end

--- 钉页分配：default 用内容高，自定义用像素，剩余均分给 fill。
---@param ranges BookHomeHeightSpec[] 各组件的内容高度与 fill 标记
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
        selected[#selected + 1] = normalize(raw)
    end
    if #selected == 0 then return selected, {}, available end

    local gaps = gap * (#selected - 1)
    local heights = {}
    local fill_idx = {}
    for i, item in ipairs(selected) do
        if type(item.mode) == "number" then
            heights[i] = height(item.mode, item.height)
        else
            heights[i] = item.height
        end
        if item.fill then fill_idx[#fill_idx + 1] = i end
    end

    local used = gaps
    for i = 1, #heights do used = used + heights[i] end
    local remaining = available - used

    if remaining < 0 then
        local scale = (available - gaps) / math.max(1, used - gaps)
        for i = 1, #heights do
            heights[i] = math.max(1, math.floor(heights[i] * scale))
        end
        used = gaps
        for i = 1, #heights do used = used + heights[i] end
        return selected, heights, math.max(0, available - used)
    end

    if #fill_idx > 0 and remaining > 0 then
        local n = #fill_idx
        local share = math.floor(remaining / n)
        local extra = remaining % n
        for j, i in ipairs(fill_idx) do
            heights[i] = heights[i] + share + (j <= extra and 1 or 0)
        end
        remaining = 0
    end

    return selected, heights, remaining
end

--- 迁移用：按内容高度自动切页（旧行为）。
---@param ranges BookHomeHeightSpec[] 各组件的内容高度
---@param available number 当前布局可用的总高度，单位像素
---@param gap number 相邻项目间距，单位像素
---@return table[] pages
function Layout:paginate(ranges, available, gap)
    available = math.max(0, math.floor(tonumber(available) or 0))
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    local pages, cur = {}, {}
    local used = 0

    --- 把当前累积的组件提交为一页，开始下一页的布局。
    ---@return nil
    local function flush()
        pages[#pages + 1] = cur
        cur, used = {}, 0
    end

    for _, raw in ipairs(ranges) do
        local h = specHeight(raw)
        local pad = #cur > 0 and gap or 0
        if #cur > 0 and used + pad + h > available then
            flush()
            pad = 0
        end
        cur[#cur + 1] = raw
        used = used + pad + h
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
                    height = item.height,
                    fill = item.fill,
                    limit = body_h,
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
