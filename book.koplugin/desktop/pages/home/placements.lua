--[[--
首页钉页放置表：读写 home_widgets，页码压缩、排序、容量检查。

@module koplugin.book.desktop.pages.home.placements
--]]

local MoonSettings = require("utils.settings")

---@class BookHomeWidgetPlacement
---@field id string
---@field page number
---@field order number
---@field height "default"|"fill"|number

local M = {}

--- 默认放置：全部第 1 页，顺序同注册顺序。
---@param components { id: string }[]
---@return BookHomeWidgetPlacement[]
local function defaults(components)
    local out = {}
    for i, comp in ipairs(components) do
        out[i] = { id = comp.id, page = 1, order = i, height = "default" }
    end
    return out
end

---@return "default"|"fill"|number
local function normalizeHeight(height)
    if height == "fill" or height == "default" then return height end
    local n = tonumber(height)
    if n then return math.max(1, math.floor(n)) end
    return "default"
end

--- 净化放置表：合法 id、去重、页/序规范化；没有可用记录时回到默认放置。
---@param components { id: string }[] 已注册组件，按注册顺序
---@return BookHomeWidgetPlacement[]
function M.sanitize(raw, components)
    if type(raw) ~= "table" then return defaults(components) end
    local known = {}
    for _idx, comp in ipairs(components) do known[comp.id] = true end
    local out, seen = {}, {}
    for _idx, item in ipairs(raw) do
        if type(item) == "table" then
            local id = item.id
            if type(id) == "string" and not seen[id] and known[id] then
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
    if #out == 0 then return defaults(components) end
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
    for _idx, item in ipairs(list) do
        local p = item.page
        by_page[p] = by_page[p] or {}
        by_page[p][#by_page[p] + 1] = item
    end
    local pages = {}
    for p in pairs(by_page) do pages[#pages + 1] = p end
    table.sort(pages)
    local out = {}
    for _idx, p in ipairs(pages) do
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

--- 删空页后把后面页码前移。
---@param list BookHomeWidgetPlacement[]
---@return BookHomeWidgetPlacement[]
function M.compactPages(list)
    local used = {}
    for _idx, item in ipairs(list) do used[item.page] = true end
    local pages = {}
    for p in pairs(used) do pages[#pages + 1] = p end
    table.sort(pages)
    local map = {}
    for i, p in ipairs(pages) do map[p] = i end
    local out = {}
    for _idx, item in ipairs(list) do
        out[#out + 1] = {
            id = item.id,
            page = map[item.page],
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
    for _idx, item in ipairs(list) do
        if item.page > max_p then max_p = item.page end
    end
    return max_p
end

---@param list BookHomeWidgetPlacement[]
---@param page number
---@return BookHomeWidgetPlacement[]
function M.onPage(list, page)
    local out = {}
    for _idx, item in ipairs(list) do
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
    for _idx, item in ipairs(list) do out[#out + 1] = item.id end
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
    local home = MoonSettings.get("desktop.pages.home")
    home.home_widgets = list
    MoonSettings.save("desktop.pages.home", home)
end

--- 读并净化当前放置表。
---@param components { id: string }[] 已注册组件，按注册顺序
---@return BookHomeWidgetPlacement[]
function M.load(components)
    local home = MoonSettings.get("desktop.pages.home")
    return M.sanitize(home.home_widgets, components)
end

--- 本页已用内容高度 + gap 后，能否再塞 candidate。
---@param placed number[]
---@param candidate number
---@param available number
---@param gap number
---@return boolean
function M.canFit(placed, candidate, available, gap)
    local used = candidate
    for _idx, h in ipairs(placed) do used = used + h + gap end
    return used <= available
end

--- 当前页能放下则留在 current，否则落到末页之后。
---@param list BookHomeWidgetPlacement[]
---@param current_page number
---@param fits boolean
---@return number page
---@return number order
function M.appendSlot(list, current_page, fits)
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
    for _idx, item in ipairs(list) do by_id[item.id] = item end
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
