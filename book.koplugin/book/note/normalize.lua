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
        if type(item) == "table" and item.datetime
            and (item.page or item.pageref or item.wr_range) then
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
                wr_range = item.wr_range,
                wr_bookmark_id = item.wr_bookmark_id,
                wr_review_id = item.wr_review_id,
            }
        end
    end
    return result
end

---@param item table
---@return integer
function Normalize.bucketKey(item)
    local idx = tonumber(item.chapter_idx)
    return idx and idx > 0 and idx or 0
end

---@param item table
---@return boolean
function Normalize.renderable(item)
    if type(item.page) ~= "string" or item.page == "" then return false end
    if not item.drawer then return true end
    return type(item.pos0) == "string" and item.pos0 ~= ""
        and type(item.pos1) == "string" and item.pos1 ~= ""
end

---@param remote table[]
---@param local_items table[]
---@return table[]
function Normalize.merge(remote, local_items)
    local merged, seen = {}, {}
    for _, item in ipairs(remote or {}) do
        if type(item) == "table" and Normalize.renderable(item) then
            local key = item.wr_bookmark_id
                or table.concat({ tostring(item.text or ""), tostring(item.wr_range or "") }, "\31")
            seen[key] = true
            merged[#merged + 1] = item
        end
    end
    for _, item in ipairs(local_items or {}) do
        if type(item) == "table" and not item.wr_bookmark_id and Normalize.renderable(item) then
            merged[#merged + 1] = item
        end
    end
    return merged
end

return Normalize
