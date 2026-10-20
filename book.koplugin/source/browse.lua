--[[--
书城浏览的公共部分：按页顺序拉到够数为止。各源的榜单 / 分类怎么取、怎么分组由源自己决定。

@module koplugin.book.source.browse
--]]

local Browse = {}

--- 从第 1 页起顺序拉，直到凑够 limit、某页为空或源说没有更多。
---@param fetch fun(page: integer, cb: fun(books: Book[]|nil, err: string|nil, more: boolean|nil)): { cancel: fun() }|nil
---@param limit integer
---@param groups StoreChipGroup[]
---@param cb fun(res: { data: Book[], groups: StoreChipGroup[] }|nil, err: string|nil)
---@return { cancel: fun() }
function Browse.pages(fetch, limit, groups, cb)
    local handle, books = {}, {}
    local function more(page)
        handle.inner = fetch(page, function(list, err, has_more)
            if not list then
                cb(nil, err)
                return
            end
            for _idx, book in ipairs(list) do books[#books + 1] = book end
            if #books < limit and #list > 0 and has_more ~= false then
                more(page + 1)
                return
            end
            cb({ data = books, groups = groups })
        end)
    end
    more(1)
    function handle.cancel()
        if handle.inner then handle.inner.cancel() end
    end
    return handle
end

--- 把 { id, title } 列表里 id 等于 node 的标为 active。
---@param chips { id: string, title: string }[]
---@param node string
---@return StoreChipGroup
function Browse.group(chips, node)
    local active
    for _idx, chip in ipairs(chips) do
        if chip.id == node then active = node end
    end
    return { chips = chips, active = active }
end

return Browse
