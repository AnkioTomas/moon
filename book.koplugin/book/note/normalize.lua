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

--- 远端注解与阅读器现有注解合并；远端优先，本地只补远端没有的。
---
--- 本地条目带 ``wr_bookmark_id`` 但远端这次没报的，仍然保留：远端「确实删了」与
--- 「这次没报上来」在 wire 上区分不了，与 saveRemoteBuckets 同一立场——宁可漏掉
--- 云端删除，也不能把本地划线清掉。
---@param remote table[]
---@param local_items table[]
---@param paging boolean|nil 目标文档是否分页文档（决定注解形态）
---@return table[]
function Normalize.merge(remote, local_items, paging)
    --- 「选中文本 + range」这一路键：本地副本回填 wr_bookmark_id 之前只能靠它认亲。
    --- 无选中文本的条目（纯书签）返回 nil：它们彼此没有区分度，拿空串当键会让
    --- 所有无文本书签互相判重，只剩一条。
    ---@param item table
    ---@return string|nil
    local function textKey(item)
        local text = item.text
        if type(text) ~= "string" or text == "" then return nil end
        return table.concat({ text, tostring(item.wr_range or "") }, "\31")
    end
    local merged, seen = {}, {}
    for _, item in ipairs(remote or {}) do
        if type(item) == "table" and Normalize.renderable(item, paging) then
            -- 两种键都登记：远端条目有 id，本地那份还没有，只登记 id 会漏判成两条
            if item.wr_bookmark_id then seen[item.wr_bookmark_id] = true end
            local key = textKey(item)
            if key then seen[key] = true end
            merged[#merged + 1] = item
        end
    end
    for _, item in ipairs(local_items or {}) do
        -- seen 判定不能省：本地副本在同步回填 wr_bookmark_id 之前，
        -- 与远端那条只有文本和 range 相同，漏判就会同一句划线显示两遍。
        local key = textKey(item)
        local dup = (key ~= nil and seen[key])
            or (item.wr_bookmark_id ~= nil and seen[item.wr_bookmark_id])
        if type(item) == "table" and not dup and Normalize.renderable(item, paging) then
            merged[#merged + 1] = item
        end
    end
    return merged
end

return Normalize
