--[[--
阅读注解的纯数据归一化与合并，不访问 UI、数据库或网络。

@module koplugin.book.note.normalize
--]]

local Normalize = {}

---@param items table[]|nil
---@param total_pages integer|nil
---@return table[]
function Normalize.clean(items, total_pages)
    local result = {}
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and item.datetime and (item.page or item.pageref) then
            result[#result + 1] = {
                datetime = item.datetime,
                datetime_updated = item.datetime_updated,
                drawer = item.drawer,
                color = item.color,
                text = item.text,
                note = item.note,
                chapter = item.chapter,
                chapter_idx = item.chapter_idx,
                pageno = item.pageno,
                page = item.page or item.pageref,
                total_pages = total_pages or item.total_pages or 0,
                pos0 = item.pos0,
                pos1 = item.pos1,
            }
        end
    end
    return result
end

--- 解包持久化快照；旧版数组 payload 继续兼容。
---@param value any
---@return table[]
---@return boolean
function Normalize.unpack(value)
    if type(value) == "table" and type(value.items) == "table" then
        return value.items, value.authoritative == true
    end
    return type(value) == "table" and value or {}, false
end

---@param items table[]
---@param authoritative boolean|nil
---@return table
function Normalize.pack(items, authoritative)
    if authoritative then
        return { items = items, authoritative = true }
    end
    return items
end

---@param item table
---@return integer
function Normalize.bucketKey(item)
    local idx = tonumber(item.chapter_idx)
    return idx and idx > 0 and idx or 0
end

--- 这条注解能否交给 ReaderView 绘制。
---
--- **由文档类型决定，不看条目自己长什么样**。KOReader 的 `annotations` 是同质数组：
--- rolling 文档（EPUB/TXT）里 `page` 是 xpointer 字符串、pos0/pos1 是字符串；
--- paging 文档（PDF/CBZ/DjVu）里 `page` 是数字、pos0/pos1 是 `{x,y,page}` 表。
--- onReadSettings 按 `type(annotations[1].page)` 判断整份数据属于哪一类，混进一条
--- 异类就会把整个数组搬去 `annotations_paging`/`annotations_rolling`，本地划线随之消失。
---
--- 另外带 ``drawer`` 的必须有 pos0/pos1，否则 ReaderView:drawSavedHighlight 会对
--- nil 调 getPosFromXPointer 并终止整轮绘制。
---@param item table
---@param paging boolean|nil true=分页文档；nil 表示未知，此时两种形态都接受
---@return boolean
function Normalize.renderable(item, paging)
    local page = item.page
    if paging == true then
        if type(page) ~= "number" then return false end
        if not item.drawer then return true end
        return type(item.pos0) == "table" and type(item.pos1) == "table"
    end
    if paging == nil and type(page) == "number" then
        if not item.drawer then return true end
        return type(item.pos0) == "table" and type(item.pos1) == "table"
    end
    if type(page) ~= "string" or page == "" then return false end
    if not item.drawer then return true end
    return type(item.pos0) == "string" and item.pos0 ~= ""
        and type(item.pos1) == "string" and item.pos1 ~= ""
end

--- 通用注解合并；仅按 KOReader 坐标和内容去重，不解释源私有字段。
---@param remote table[]
---@param local_items table[]
---@param paging boolean|nil 目标文档是否分页文档（决定注解形态）
---@return table[]
function Normalize.merge(remote, local_items, paging)
    local function key(item)
        if item.page == nil then return nil end
        return table.concat({
            tostring(item.page), tostring(item.pos0 or ""), tostring(item.pos1 or ""),
            tostring(item.text or ""), tostring(item.note or ""),
        }, "\31")
    end
    local merged, seen = {}, {}
    for _, item in ipairs(remote or {}) do
        if type(item) == "table" and Normalize.renderable(item, paging) then
            local item_key = key(item)
            if item_key then seen[item_key] = true end
            merged[#merged + 1] = item
        end
    end
    for _, item in ipairs(local_items or {}) do
        local item_key = type(item) == "table" and key(item) or nil
        if type(item) == "table" and not (item_key and seen[item_key])
                and Normalize.renderable(item, paging) then
            merged[#merged + 1] = item
        end
    end
    return merged
end

return Normalize
