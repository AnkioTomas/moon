--[[--
阅读注解的纯数据归一化与合并，不访问 UI、数据库或网络。

@module koplugin.book.book.note.normalize
--]]

local Normalize = {}

--- KOReader 用「字段缺席 / nil」表示无备注、无划线样式；SQL / JSON 常把缺省写成 ""。
--- Lua 里空串为真，ReaderBookmark.getBookmarkType 会把高亮判成笔记、把书签判成划线。
---@param value any
---@return any
local function blankToNil(value)
    if value == "" then return nil end
    return value
end

---@param items table[]|nil
---@param total_pages integer|nil
---@return table[]
function Normalize.clean(items, total_pages)
    local result = {}
    for _idx, item in ipairs(items or {}) do
        if type(item) == "table" and item.datetime and (item.page or item.pageref) then
            result[#result + 1] = {
                datetime = item.datetime,
                datetime_updated = item.datetime_updated,
                drawer = blankToNil(item.drawer),
                color = item.color,
                text = item.text,
                note = blankToNil(item.note),
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
    return (Normalize.unique(result))
end

--- 按坐标和内容区分一条注解，供去重使用：同一处划线 / 书签只留一条。
--- 不含颜色、drawer、时间戳和源私有 id；那些差异不构成「另一条」。
---@param item table
---@return string|nil
function Normalize.contentKey(item)
    if type(item) ~= "table" or item.page == nil then return nil end
    local function pos(p)
        if type(p) == "table" then
            return tostring(p.page) .. "," .. tostring(p.x) .. "," .. tostring(p.y)
        end
        return tostring(p or "")
    end
    return table.concat({
        tostring(item.page), pos(item.pos0), pos(item.pos1),
        tostring(item.text or ""), tostring(item.note or ""),
    }, "\31")
end

--- 完全重复的条目只留第一条。没有 contentKey 的（例如无 page 的删除墓碑）原样保留。
---@param items table[]|nil
---@return table[]
---@return integer deduped 被折叠掉的条数
function Normalize.unique(items)
    local out, seen, deduped = {}, {}, 0
    for _idx, item in ipairs(items or {}) do
        local key = type(item) == "table" and Normalize.contentKey(item) or nil
        if key then
            if seen[key] then
                deduped = deduped + 1
            else
                seen[key] = true
                out[#out + 1] = item
            end
        else
            out[#out + 1] = item
        end
    end
    return out, deduped
end

--- 解码 notes.payload：权威快照为 `{ items, authoritative }`，否则为裸数组；非法 JSON / 非表返回 nil。
---@param payload string|nil
---@return table[]|nil
---@return boolean authoritative
function Normalize.decode(payload)
    local ok, value = pcall(require("json").decode, payload or "[]")
    if not ok or type(value) ~= "table" then return nil, false end
    if type(value.items) == "table" then
        return value.items, value.authoritative == true
    end
    return value, false
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
---@return table[] merged
---@return integer dropped 通用合并不解释远端删除，恒为 0
---@return integer deduped 因内容键重复被折叠的条数（含远端列表内部重复）
function Normalize.merge(remote, local_items, paging)
    ---@param item table
    ---@return boolean
    local function usable(item)
        return type(item) == "table" and Normalize.renderable(item, paging)
    end
    -- 远端列表自己也可能带重复（历史合并把同一条又追加进去）。必须先折叠，
    -- 否则只对「本地对远端」去重时，库里已经膨胀的快照会原样画出来。
    local merged, seen, deduped = {}, {}, 0
    for _idx, item in ipairs(remote or {}) do
        if usable(item) then
            local item_key = Normalize.contentKey(item)
            if item_key and seen[item_key] then
                deduped = deduped + 1
            else
                if item_key then seen[item_key] = true end
                merged[#merged + 1] = item
            end
        end
    end
    for _idx, item in ipairs(local_items or {}) do
        if usable(item) then
            local item_key = Normalize.contentKey(item)
            if item_key and seen[item_key] then
                deduped = deduped + 1
            else
                if item_key then seen[item_key] = true end
                merged[#merged + 1] = item
            end
        end
    end
    return merged, 0, deduped
end

return Normalize
