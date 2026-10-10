--[[--
图书馆筛选：全屏主题列表，每个维度一个分栏（数据源 / 分类 / 系列 / 状态 / 排序）。
点选即生效且不关窗，再点已选项取消；左上角「全部清除」只保留搜索词。

  +-------------------------------+
  | [清除]      筛选          [×] |
  | (•) 科幻（12）                |
  | (o) 未分类（3）               |
  | [<]        1 / 2         [>]  |
  |  [数据源] [分类] [系列] …     |
  +-------------------------------+

@module koplugin.book.desktop.pages.library.filter
--]]

local List = require("ui.themes.widgets.list")
local _ = require("gettext")
local T = require("ffi/util").template

local Filter = {}
-- 「空值」选项（未分类 / 无系列）落在独立布尔字段上。
local FLAG = { category = "uncategorized", series = "unseries" }

local function copy(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

local function selected(d, kind, value)
    local flag = FLAG[kind]
    if flag and value == "" then return not not d[flag] end
    return d[kind] == value
end

local function choose(d, kind, value)
    if kind == "sort" then d.sort = value; return end
    local flag = FLAG[kind]
    if selected(d, kind, value) then
        d[kind] = nil
        if flag then d[flag] = nil end
    elseif flag then
        d[kind], d[flag] = value ~= "" and value or nil, value == "" or nil
    else
        d[kind] = value
    end
end

local function values(rows, kind, key, empty_label)
    local out = {}
    for _idx, item in ipairs(rows) do
        local v = item[key] or ""
        out[#out + 1] = { kind = kind, value = v, text = v ~= "" and v or empty_label, count = tonumber(item.count) or 0 }
    end
    return out
end

--- 按筛选数据生成分栏；每栏是 { id, text, icon, values = { kind, value, text, count } }。
---@param data table filtersAsync 返回的 data
---@return table[]
local function groups(data)
    local out = {}
    local src = {}
    -- 混合模式才有 source_counts；单源不显示源栏。
    for _idx, row in ipairs(data.source_counts or {}) do
        src[#src + 1] = {
            kind = "source_id",
            value = row.source_id,
            text = row.name,
            count = tonumber(row.count) or 0,
        }
    end
    if #src > 0 then out[#out + 1] = { id = "source_id", text = _("数据源"), icon = "source", values = src } end
    out[#out + 1] = { id = "category", text = _("分类"), icon = "category",
        values = values(data.category_counts, "category", "category", _("未分类")) }
    out[#out + 1] = { id = "series", text = _("系列"), icon = "collections_bookmark",
        values = values(data.series_counts, "series", "series", _("无系列")) }
    local status = {
        { kind = "read_status", value = "read", text = _("已读"), count = 0 },
        { kind = "read_status", value = "unread", text = _("未读"), count = 0 },
        { kind = "downloaded", value = true, text = _("已下载"), count = data.downloaded_count or 0 },
    }
    for _idx, row in ipairs(data.read_counts) do
        for _idx, item in ipairs(status) do
            if item.value == row.status then item.count = tonumber(row.count) or 0 end
        end
    end
    out[#out + 1] = { id = "status", text = _("状态"), icon = "done_all", values = status }
    out[#out + 1] = { id = "sort", text = _("排序"), icon = "sort", values = {
        { kind = "sort", value = "recent_added", text = _("最近添加") },
        { kind = "sort", value = "recent_read", text = _("最近阅读") },
        { kind = "sort", value = "title", text = _("书名") },
        { kind = "sort", value = "author", text = _("作者") },
    } }
    return out
end

---@param opts { data: table, current: table, sort: string, on_apply: fun(filter: table, sort: string) }
---@return BookThemeList
function Filter.open(opts)
    local draft = copy(opts.current)
    draft.sort = opts.sort or "recent_added"
    local tabs, by_id = {}, {}
    for i, g in ipairs(groups(opts.data)) do
        tabs[i], by_id[g.id] = { id = g.id, text = g.text, icon = g.icon }, g
    end
    local list

    local function apply()
        local filter = copy(draft)
        local sort = filter.sort or "recent_added"
        filter.sort = nil
        opts.on_apply(filter, sort)
    end

    ---@param id string 分栏 id
    ---@return table[]
    local function items(id)
        local out = {}
        for i, v in ipairs(by_id[id].values) do
            out[i] = {
                text = v.count and T(_("%1（%2）"), v.text, v.count) or v.text,
                checked = selected(draft, v.kind, v.value),
                keep_open = true,
                callback = function()
                    choose(draft, v.kind, v.value)
                    apply()
                    list:setItems(items(id))
                end,
            }
        end
        return out
    end

    local first = tabs[1].id
    list = List:new{
        title = _("筛选"),
        items = items(first),
        left_icon = "filter_alt_off",
        left_callback = function()
            draft = { search = draft.search, sort = "recent_added" }
            apply()
            list:setItems(items(list.tabs.active))
        end,
        tabs = { tabs = tabs, active = first, on_tab = items },
    }
    list:show()
    return list
end

return Filter
