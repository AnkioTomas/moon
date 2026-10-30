--[[--
首页垂直布局：默认累加各组件内容高度，fill 吃页内剩余。

@module koplugin.book.desktop.pages.home.layout
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Registry = require("desktop.pages.home.registry")
local Widgets = require("desktop.pages.home.placements")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")

---@class BookHomeHeightSpec
---@field height number 内容自然高度
---@field id string|nil 组件标识（布局阶段补上）
---@field comp BookHomeComponent|nil 组件实例（布局阶段补上）
---@field placement BookHomeWidgetPlacement|nil 钉页记录（布局阶段补上）

---@class BookHomeBuildOpts
---@field wrap fun(widget: table, meta: table): table|nil
---@field body_height number|nil
---@field focus string|nil 优先落在含该组件的那一页（浏览 / 编辑态分页不同，切换时保持所见页）

local Layout = {}

-- 浏览态钉页容忍的超高比例：略超（组件加载后变高、自定义高度）由 allocate 等比压缩，与编辑态一致；
-- 超得多（横屏）才顺延成多页。
Layout.OVERFLOW_SLACK = 1.25

--- 正文区内框与组件间距：四周留 space.md，组件之间 space.sm。
---@param width number 正文宽
---@param body_h number 正文高
---@return number inner_w
---@return number inner_h
---@return number gap
function Layout.metrics(width, body_h)
    local t = Theme.current()
    local inset = Theme.px(t.space.md)
    return math.max(1, width - inset * 2), math.max(1, body_h - inset * 2), Theme.px(t.space.sm)
end

--- 读组件报的内容高度。
---@param raw table
---@return number
local function specHeight(raw)
    return math.max(1, math.floor(raw.height))
end

--- 放置表上下边距之和（占垂直空间，不进组件内容高）。
---@param placement BookHomeWidgetPlacement|nil
---@return number
local function marginVertical(placement)
    local top, _right, bottom = Widgets.marginBox(placement)
    return top + bottom
end

--- 切页用的高度：内容高与自定义像素高取小，再加上下边距。自定义更矮时按它算；
--- 自定义更高时仍按内容高，放不下由 allocate 等比压缩，不把页拆开。
---@param raw BookHomeHeightSpec
---@return number
function Layout.packHeight(raw)
    local mode = raw.placement and raw.placement.height
    local h = specHeight(raw)
    local content = type(mode) == "number" and math.min(mode, h) or h
    return content + marginVertical(raw.placement)
end

--- 在内容外包上下左右外边距；四边皆 0 时原样返回。
---@param widget table
---@param top number
---@param right number
---@param bottom number
---@param left number
---@return table
function Layout.pad(widget, top, right, bottom, left)
    if top <= 0 and right <= 0 and bottom <= 0 and left <= 0 then return widget end
    local row = HorizontalGroup:new{ align = "top", widget }
    if left > 0 then table.insert(row, 1, HorizontalSpan:new{ width = left }) end
    if right > 0 then row[#row + 1] = HorizontalSpan:new{ width = right } end
    local col = VerticalGroup:new{ align = "left", row }
    if top > 0 then table.insert(col, 1, VerticalSpan:new{ width = top }) end
    if bottom > 0 then col[#col + 1] = VerticalSpan:new{ width = bottom } end
    return col
end

--- 钉页分配：default 用内容高，自定义用像素，再加上下边距；剩余均分给 fill；放不下时整体等比压缩。
--- 页边距由 build 整页扣一次，这里只算内容高、组件边距和 gap。
---@param ranges BookHomeHeightSpec[] 各组件的内容高度
---@param available number 当前布局可用的总高度，单位像素
---@param gap number 相邻项目间距，单位像素
---@return table[] selected
---@return number[] heights 含边距的槽高
---@return number unused
function Layout.allocate(ranges, available, gap)
    local selected, heights, fill_idx = {}, {}, {}
    local gaps = gap * math.max(0, #ranges - 1)
    local used = gaps
    for i, raw in ipairs(ranges) do
        local mode = raw.placement and raw.placement.height or "default"
        local h = specHeight(raw)
        local mv = marginVertical(raw.placement)
        selected[i] = { comp = raw.comp, id = raw.id, placement = raw.placement, height = h, fill = mode == "fill", margin_v = mv }
        heights[i] = (type(mode) == "number" and mode or h) + mv
        if mode == "fill" then fill_idx[#fill_idx + 1] = i end
        used = used + heights[i]
    end
    local remaining = available - used

    if remaining < 0 then
        local scale = (available - gaps) / math.max(1, used - gaps)
        used = gaps
        for i = 1, #heights do
            heights[i] = math.max(1, math.floor(heights[i] * scale))
            used = used + heights[i]
        end
        return selected, heights, math.max(0, available - used)
    end

    local n = #fill_idx
    if n > 0 then
        local share = math.floor(remaining / n)
        local extra = remaining % n
        for j, i in ipairs(fill_idx) do
            heights[i] = heights[i] + share + (j <= extra and 1 or 0)
        end
        remaining = 0
    end
    return selected, heights, remaining
end

--- 按内容高度自动切页（首装 `home_widgets==nil` 时用）。
---@param ranges BookHomeHeightSpec[] 各组件的内容高度
---@param available number 当前布局可用的总高度，单位像素
---@param gap number 相邻项目间距，单位像素
---@return table[] pages
function Layout.paginate(ranges, available, gap)
    local pages, cur, used = {}, {}, 0
    for _idx, raw in ipairs(ranges) do
        local h = Layout.packHeight(raw)
        if #cur > 0 and used + gap + h > available then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        used = used + (#cur > 0 and gap or 0) + h
        cur[#cur + 1] = raw
    end
    pages[#pages + 1] = cur
    return pages
end

--- 组装一页内容。page 从 1 起；页边界由 home_widgets 钉死。
---@param ctx BookDesktopCtx 构建上下文，提供尺寸、数据源和桌面宿主
---@param components table<string, BookHomeComponent>
---@param page number 当前页码，从 1 开始
---@param opts BookHomeBuildOpts|nil
---@return table widget
---@return number page
---@return number pages
---@return table<string, boolean> visible
function Layout.build(ctx, components, page, opts)
    ---@type BookHomeBuildOpts
    opts = opts or {}
    local w = ctx.width
    local body_h = opts.body_height or ctx.height
    local placements = Registry.widgets()
    local inner_w, inner_h, gap = Layout.metrics(w, body_h)

    -- 钉页是按创建时的屏幕定的；屏幕变矮（横屏）放不下的页顺延成多页，钉页记录不动。编辑态只认钉页。
    local display = {}
    for pinned = 1, Widgets.pageCount(placements) do
        local ranges = {}
        for _idx, place in ipairs(Widgets.onPage(placements, pinned)) do
            local comp = components[place.id]
            if comp then
                local range = comp:heightRange(ctx, { width = inner_w, height = inner_h })
                range.comp = comp
                range.id = place.id
                range.placement = place
                ranges[#ranges + 1] = range
            end
        end
        if opts.wrap then
            display[#display + 1] = ranges
        else
            for _idx, pack in ipairs(Layout.paginate(ranges, math.floor(inner_h * Layout.OVERFLOW_SLACK), gap)) do display[#display + 1] = pack end
        end
    end
    local pages = #display
    for i, ranges in ipairs(display) do
        for _idx, raw in ipairs(ranges) do
            if raw.id == opts.focus then page = i end
        end
    end
    page = math.max(1, math.min(pages, page))
    local ranges = display[page]

    local selected, heights, unused = Layout.allocate(ranges, inner_h, gap)
    local kids = { align = "left" }
    local visible = {}
    for i, item in ipairs(selected) do
        visible[item.id] = true
        if i > 1 then kids[#kids + 1] = VerticalSpan:new{ width = gap } end
        local top, right, bottom, left = Widgets.marginBox(item.placement)
        local slot_h = heights[i]
        -- 槽高 / 行宽不够吃边距时：先留 1px 内容，边距按比例压。
        local mv = top + bottom
        if mv > 0 and slot_h <= mv then
            local scale = (slot_h - 1) / mv
            top, bottom = math.max(0, math.floor(top * scale)), math.max(0, math.floor(bottom * scale))
        end
        local mh = left + right
        if mh > 0 and inner_w <= mh then
            local scale = (inner_w - 1) / mh
            left, right = math.max(0, math.floor(left * scale)), math.max(0, math.floor(right * scale))
        end
        local content_h = math.max(1, slot_h - top - bottom)
        local content_w = math.max(1, inner_w - left - right)
        local part = item.comp:build(ctx, { width = content_w, height = content_h })
        part = Layout.pad(part, top, right, bottom, left)
        if opts.wrap then
            part = opts.wrap(part, {
                id = item.id,
                height = slot_h,
                width = inner_w,
                placement = item.placement,
                range = { height = item.height, fill = item.fill, limit = inner_h },
            })
        end
        kids[#kids + 1] = part
    end
    if unused > 0 then kids[#kids + 1] = VerticalSpan:new{ width = unused } end

    local body = Box:new{ style = {}, width = w, height = body_h, VerticalGroup:new(kids) }
    return body, page, pages, visible
end

return Layout
