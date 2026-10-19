--[[--
图书馆工具条的两个下拉：排序、筛选（阅读状态 / 已下载 / 软删除，混合源时加数据源）。
主题 List 居中面板贴着按钮弹出（带遮罩、点外面关），当前项画单选圈，点选即关窗回调新值。
分类 / 系列 / 作者归顶部分组页签，不在这里。

  [最近阅读 ▾]          [全部 ▾]
  +-------------+       +----------------+
  | ( ) 最近添加 |       | (•) 全部        |
  | (•) 最近阅读 |       | ( ) 未读（210） |
  | ( ) 书名     |       | …              |
  +-------------+       | ▣ 微信读书（3） |
                        +----------------+

@module koplugin.book.desktop.pages.library.filter
--]]

require("l10n").apply()

local List = require("ui.themes.widgets.list")
local Theme = require("ui.themes")
local _ = require("gettext")
local T = require("ffi/util").template

local Filter = {}

-- 下拉内容宽（逻辑像素）：够放「最近阅读」「已下载（9999）」与数据源名。
local MENU_W = 220

--- 排序项，顺序即菜单顺序；id 即持久化的 library_sort。
---@return { id: string, text: string }[]
function Filter.sorts()
    return {
        { id = "recent_added", text = _("最近添加") },
        { id = "recent_read", text = _("最近阅读") },
        { id = "title", text = _("书名") },
        { id = "author", text = _("作者") },
    }
end

--- 阅读状态项：互斥单选，各项同时决定 read_status / downloaded / hidden 三个字段。
---@return { id: string, text: string, read_status: string|nil, downloaded: boolean|nil, hidden: boolean|nil }[]
function Filter.statuses()
    return {
        { id = "all", text = _("全部") },
        { id = "unread", text = _("未读"), read_status = "unread" },
        { id = "read", text = _("已读"), read_status = "read" },
        { id = "downloaded", text = _("已下载"), downloaded = true },
        { id = "hidden", text = _("软删除"), hidden = true },
    }
end

--- 筛选条件对应的状态项。
---@param filter table
---@return table
function Filter.status(filter)
    local list = Filter.statuses()
    for _idx, s in ipairs(list) do
        if s.read_status == filter.read_status and s.downloaded == filter.downloaded
            and s.hidden == filter.hidden then return s end
    end
    return list[1]
end

--- 排序 id 对应的文案。
---@param id string
---@return string
function Filter.sortText(id)
    for _idx, s in ipairs(Filter.sorts()) do
        if s.id == id then return s.text end
    end
    return Filter.sorts()[1].text
end

local function copy(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

local function show(anchor, items)
    local list = List:new{ centered = true, anchor = anchor, inner_width = Theme.px(MENU_W), items = items }
    list:show()
    return list
end

--- 排序下拉。
---@param anchor table 按钮矩形
---@param current string 当前排序 id
---@param on_pick fun(sort: string)
---@return table list
function Filter.openSort(anchor, current, on_pick)
    local items = {}
    for i, s in ipairs(Filter.sorts()) do
        items[i] = { text = s.text, checked = s.id == current, callback = function() on_pick(s.id) end }
    end
    return show(anchor, items)
end

--- 筛选下拉：阅读状态单选；混合源时接着列数据源（带源图标），再点已选源取消。
---@param anchor table 按钮矩形
---@param data table filtersAsync 返回的 data
---@param filter table 当前筛选条件（不修改，回调拿副本）
---@param on_pick fun(filter: table)
---@return table list
function Filter.openStatus(anchor, data, filter, on_pick)
    local counts = { read = 0, unread = 0, downloaded = data.downloaded_count or 0, hidden = data.hidden_count or 0 }
    for _idx, row in ipairs(data.read_counts or {}) do
        counts[row.status] = tonumber(row.count) or 0
    end
    local current = Filter.status(filter).id
    local items = {}
    for _idx, s in ipairs(Filter.statuses()) do
        items[#items + 1] = {
            text = counts[s.id] and T(_("%1（%2）"), s.text, counts[s.id]) or s.text,
            checked = s.id == current,
            callback = function()
                local f = copy(filter)
                f.read_status, f.downloaded, f.hidden = s.read_status, s.downloaded, s.hidden
                on_pick(f)
            end,
        }
    end
    for _idx, row in ipairs(data.source_counts or {}) do
        local on = filter.source_id == row.source_id
        items[#items + 1] = {
            text = T(_("%1（%2）"), row.name, tonumber(row.count) or 0),
            icon = "source",
            checked = on,
            callback = function()
                local f = copy(filter)
                f.source_id = not on and row.source_id or nil
                on_pick(f)
            end,
        }
    end
    return show(anchor, items)
end

return Filter
