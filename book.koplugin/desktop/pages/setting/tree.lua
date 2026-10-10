--[[--
设置树：分组 → 页面 → 分节，三层按 order 合并。

条目来自两处，格式相同：核心在 `desktop/pages/setting/init.lua` 声明；feature 经 `Features.scan`
扫描 `features/*/setting.lua`，取其 `entries(desktop)`（没有 entries 的只放配置默认值，跳过）。

每条必须有数字 `order`，且 `group` / `parent` 二选一：
  - `group = 分组 id`：挂到根页该分组下。带 `page`（title、可选 preview / sections）是导航行，点开叠层；
    带 `row = fn(iw)` 是直接放在分组里的行。
  - `parent = 页面 id`：往该页追加分节，`sections = fn() → BookThemeSection[]`，排在页面自带 sections 之后。
同层按 order 升序；order 相同按收集顺序（核心在前，feature 按目录名）。
feature 的页面 id 是 `feature:<name>:<id>`（id 省略用序号），核心页面用自己写的 id；parent 引用的就是这个 id。

@module koplugin.book.desktop.pages.setting.tree
--]]

---@class BookSettingPage
---@field title string
---@field preview (fun(width: number): table)|nil
---@field sections (fun(): table[])|nil 页面自带分节；全靠第三层追加时可省略

---@class BookSettingEntry
---@field order number 同层排序
---@field group string|nil 第二层：挂到的根页分组
---@field parent string|nil 第三层：追加分节的页面 id
---@field id string|nil 页面 id；feature 省略时用序号
---@field icon string|nil
---@field title string|nil
---@field subtitle string|nil
---@field status string|nil
---@field status_on boolean|nil
---@field page BookSettingPage|nil 导航行打开的页面
---@field row (fun(iw: number): table)|nil 直接放在分组里的行
---@field sections (fun(): table[])|nil 第三层追加的分节
---@field owner string|nil 报错用的来源标签

--- 合并后的第二层条目：page 已换成叠层规格。
---@class BookSettingNode
---@field order number
---@field id string|nil
---@field icon string|nil
---@field title string|nil
---@field subtitle string|nil
---@field status string|nil
---@field status_on boolean|nil
---@field page BookSettingsOverlaySpec|nil
---@field row (fun(iw: number): table)|nil

local Tree = {}

---@param t table
---@return table
local function copy(t)
    local out = {}
    for key, value in pairs(t) do out[key] = value end
    return out
end

--- 扫描收集 feature 条目；页面 id 加 `feature:<name>:` 前缀，不改 feature 返回的表。
---@param desktop BookDesktop
---@return BookSettingEntry[]
function Tree.features(desktop)
    local out = {}
    for _idx, name in ipairs(require("features").scan("setting")) do
        local mod = require("features." .. name .. ".setting")
        if mod.entries then
            local entries = mod.entries(desktop)
            -- 单条也必须是数组。误返回一条设置表时不能静默丢掉。
            if type(entries) ~= "table" or entries.order or entries.page or entries.row or entries.sections then
                error("feature " .. name .. " setting: entries must return a list")
            end
            for i, entry in ipairs(entries) do
                local item = copy(entry)
                item.owner = "feature " .. name
                if item.page then item.id = "feature:" .. name .. ":" .. (entry.id or i) end
                out[#out + 1] = item
            end
        end
    end
    return out
end

--- 按层级合并。返回根页分组（顺序同 groups），每组 entries 已排序；
--- 导航条目的 page 换成叠层规格：id = 条目 id，sections 每次调用都重算自带分节 + 追加分节。
---@param groups { id: string, title: string }[]
---@param entries BookSettingEntry[]
---@return { id: string, title: string, entries: BookSettingNode[] }[]
function Tree.build(groups, entries)
    local by_group, pages, children, seq = {}, {}, {}, {}
    for _idx, group in ipairs(groups) do by_group[group.id] = {} end
    for i, raw in ipairs(entries) do
        local entry = copy(raw)
        local who = (entry.owner or "core") .. " setting"
        seq[entry] = i
        if type(entry.order) ~= "number" then error(who .. ": entry needs order") end
        if entry.group then
            local list = by_group[entry.group]
            if not list then error(who .. ": unknown group " .. tostring(entry.group)) end
            if entry.page then
                if not entry.id or not entry.page.title then error(who .. ": page needs id and title") end
                if pages[entry.id] then error(who .. ": duplicate page " .. entry.id) end
                pages[entry.id] = entry
            elseif type(entry.row) ~= "function" then
                error(who .. ": group entry needs page or row")
            end
            list[#list + 1] = entry
        elseif entry.parent then
            if type(entry.sections) ~= "function" then error(who .. ": parent entry needs sections") end
            children[entry.parent] = children[entry.parent] or {}
            table.insert(children[entry.parent], entry)
        else
            error(who .. ": entry needs group or parent")
        end
    end

    local function sort(list)
        table.sort(list, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            return seq[a] < seq[b]
        end)
    end
    for parent, list in pairs(children) do
        if not pages[parent] then error((list[1].owner or "core") .. " setting: unknown parent " .. parent) end
        sort(list)
    end
    for id, entry in pairs(pages) do
        local page, extra = entry.page, children[id] or {}
        if not page.sections and #extra == 0 then error((entry.owner or "core") .. " setting: page " .. id .. " has no sections") end
        entry.page = {
            id = id,
            title = page.title,
            preview = page.preview,
            sections = function()
                local out = {}
                for _idx, section in ipairs(page.sections and page.sections() or {}) do out[#out + 1] = section end
                for _idx, child in ipairs(extra) do
                    for _i, section in ipairs(child.sections()) do out[#out + 1] = section end
                end
                return out
            end,
        }
    end

    local out = {}
    for _idx, group in ipairs(groups) do
        local list = by_group[group.id]
        sort(list)
        out[#out + 1] = { id = group.id, title = group.title, entries = list }
    end
    return out
end

return Tree
