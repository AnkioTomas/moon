--[[--
首页钉页放置表：读写 home_widgets，页码压缩、排序、容量检查。

@module koplugin.book.ui.desktop.home.widgets
--]]

local MoonSettings = require("utils.settings")

---@class BookHomeWidgetPlacement
---@field id string
---@field page number
---@field order number
---@field height "default"|"fill"|number

local M = {}

local DEFAULT_IDS = {
    "clock", "weather", "clock_weather", "stats", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards",
}

--- 默认放置：全部第 1 页，顺序与目录一致。
---@return BookHomeWidgetPlacement[]
function M.defaults()
    local out = {}
    for i, id in ipairs(DEFAULT_IDS) do
        out[i] = { id = id, page = 1, order = i, height = "default" }
    end
    return out
end

---@param height any
---@return "default"|"fill"|number
local function normalizeHeight(height)
    if height == "fill" or height == "default" then return height end
    local n = tonumber(height)
    if n then return math.max(1, math.floor(n)) end
    return "default"
end

--- 净化放置表：合法 id、去重、页/序规范化。
---@param raw any
---@param find fun(id: string): any
---@return BookHomeWidgetPlacement[]
function M.sanitize(raw, find)
    if type(raw) ~= "table" then return M.defaults() end
    local out, seen = {}, {}
    for _, item in ipairs(raw) do
        if type(item) == "table" then
            local id = item.id
            if type(id) == "string" and id ~= "" and not seen[id] and find(id) then
                seen[id] = true
                out[#out + 1] = {
                    id = id,
                    page = math.max(1, math.floor(tonumber(item.page) or 1)),
                    order = math.max(1, math.floor(tonumber(item.order) or (#out + 1))),
                    height = normalizeHeight(item.height),
                }
            end
        end
    end
    if #out == 0 then return M.defaults() end
    table.sort(out, function(a, b)
        if a.page ~= b.page then return a.page < b.page end
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return M.reindex(out)
end

--- 按页重排 order 为 1..n，页码保持。
---@param list BookHomeWidgetPlacement[]
---@return BookHomeWidgetPlacement[]
function M.reindex(list)
    local by_page = {}
    for _, item in ipairs(list) do
        local p = item.page
        by_page[p] = by_page[p] or {}
        by_page[p][#by_page[p] + 1] = item
    end
    local pages = {}
    for p in pairs(by_page) do pages[#pages + 1] = p end
    table.sort(pages)
    local out = {}
    for _, p in ipairs(pages) do
        local row = by_page[p]
        table.sort(row, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            return a.id < b.id
        end)
        for i, item in ipairs(row) do
            out[#out + 1] = {
                id = item.id,
                page = p,
                order = i,
                height = item.height,
            }
        end
    end
    return out
end

--- 删空页后把后面页码前移；至少保留 page=1。
---@param list BookHomeWidgetPlacement[]
---@return BookHomeWidgetPlacement[]
function M.compactPages(list)
    local by_page = {}
    for _, item in ipairs(list) do
        by_page[item.page] = by_page[item.page] or {}
        by_page[item.page][#by_page[item.page] + 1] = item
    end
    local pages = {}
    for p, row in pairs(by_page) do
        if #row > 0 then pages[#pages + 1] = p end
    end
    table.sort(pages)
    if #pages == 0 then return M.defaults() end
    local map = {}
    for i, p in ipairs(pages) do map[p] = i end
    local out = {}
    for _, item in ipairs(list) do
        out[#out + 1] = {
            id = item.id,
            page = map[item.page] or 1,
            order = item.order,
            height = item.height,
        }
    end
    return M.reindex(out)
end

---@param list BookHomeWidgetPlacement[]
---@return number
function M.pageCount(list)
    local max_p = 1
    for _, item in ipairs(list) do
        if item.page > max_p then max_p = item.page end
    end
    return max_p
end

---@param list BookHomeWidgetPlacement[]
---@param page number
---@return BookHomeWidgetPlacement[]
function M.onPage(list, page)
    local out = {}
    for _, item in ipairs(list) do
        if item.page == page then out[#out + 1] = item end
    end
    table.sort(out, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return out
end

---@param list BookHomeWidgetPlacement[]
---@return string[]
function M.ids(list)
    local out = {}
    for _, item in ipairs(list) do out[#out + 1] = item.id end
    return out
end

---@param list BookHomeWidgetPlacement[]
---@param id string
---@return BookHomeWidgetPlacement|nil
---@return number|nil
function M.find(list, id)
    for i, item in ipairs(list) do
        if item.id == id then return item, i end
    end
    return nil, nil
end

--- 写回设置。
---@param list BookHomeWidgetPlacement[]
function M.save(list)
    local home = MoonSettings.get("home")
    home.home_widgets = list
    MoonSettings.saveSection("home", home)
end

--- 读并净化当前放置表。
---@param find fun(id: string): any
---@return BookHomeWidgetPlacement[]
function M.load(find)
    local home = MoonSettings.get("home")
    return M.sanitize(home.home_widgets, find)
end

--- 本页已用内容高度 + gap 后，能否再塞 candidate。
---@param placed number[]
---@param candidate number
---@param available number
---@param gap number
---@return boolean
function M.canFit(placed, candidate, available, gap)
    available = math.max(0, math.floor(tonumber(available) or 0))
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    candidate = math.max(1, math.floor(tonumber(candidate) or 1))
    local used = 0
    for i, h in ipairs(placed) do
        used = used + math.max(1, math.floor(h))
        if i > 1 then used = used + gap end
    end
    local need = candidate
    if #placed > 0 then need = need + gap end
    return used + need <= available
end

--- 当前页能放下则留在 current，否则落到末页之后。
---@param list BookHomeWidgetPlacement[]
---@param current_page number
---@param fits boolean
---@return number page
---@return number order
function M.appendSlot(list, current_page, fits)
    current_page = math.max(1, math.floor(tonumber(current_page) or 1))
    if fits then
        return current_page, #M.onPage(list, current_page) + 1
    end
    return M.pageCount(list) + 1, 1
end

--- 按 paginate 结果给放置表赋 page/order（首装钉页）。
---@param list BookHomeWidgetPlacement[] 按全局顺序
---@param packs table[] paginate 返回的页，每页含 {id=...} 或带 id 的 range
---@return BookHomeWidgetPlacement[]
function M.applyPacks(list, packs)
    local by_id = {}
    for _, item in ipairs(list) do by_id[item.id] = item end
    local out = {}
    for page, pack in ipairs(packs) do
        for order, raw in ipairs(pack) do
            local id = raw.id or raw
            local prev = by_id[id]
            if prev then
                out[#out + 1] = {
                    id = id,
                    page = page,
                    order = order,
                    height = prev.height or "default",
                }
            end
        end
    end
    if #out == 0 then return list end
    return M.reindex(out)
end

return M
