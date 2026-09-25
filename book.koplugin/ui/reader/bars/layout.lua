--[[--
阅读页顶栏 / 底栏布局。

有序列表：`{ { id, align }, ... }`。不在列表里的组件就是关。
替代系统栏默认开，和现在的 overlay 行为一致。

@module koplugin.book.ui.reader.bars.layout
--]]

local MoonSettings = require("utils.settings")

local Layout = {}

local KEY = {
    top = "book_reader_top_bar_layout",
    bottom = "book_reader_bottom_bar_layout",
}

local REPLACE_KEY = {
    top = "book_reader_replace_top_bar",
    bottom = "book_reader_replace_bottom_bar",
}

local DEFAULTS = {
    top = {
        { id = "chapter", align = "left" },
        { id = "clock", align = "right" },
    },
    bottom = {
        { id = "progress_bar", align = "left" },
        { id = "percent", align = "right" },
        { id = "chapter_idx", align = "right" },
        { id = "remaining", align = "right" },
    },
}

local DEFAULT_ALIGN = {
    chapter = "left",
    title = "left",
    page = "left",
    percent = "right",
    chapter_idx = "right",
    remaining = "right",
    clock = "right",
    battery = "right",
    wifi = "right",
    brightness = "right",
    progress_bar = "left",
}

--- 拷贝布局表，避免把默认表交出去被改。
---@param layout table
---@return table
local function copyLayout(layout)
    local out = {}
    for i = 1, #layout do
        local item = layout[i]
        out[i] = { id = item.id, align = item.align }
    end
    return out
end

--- 该栏允许的组件 id。
---@param which string "top"|"bottom"
---@return table<string, boolean>
local function allowedIds(which)
    local Items = require("ui.reader.bars.items")
    local allowed = {}
    for _, item in ipairs(Items.catalog(which)) do
        allowed[item.id] = true
    end
    return allowed
end

--- 清洗用户布局：已知 id、不重复、align 只有 left/right。
---@param which string
---@return table
local function sanitize(which, raw)
    if type(raw) ~= "table" then
        return copyLayout(DEFAULTS[which])
    end
    local allowed = allowedIds(which)
    local seen, out = {}, {}
    for i = 1, #raw do
        local item = raw[i]
        local id = type(item) == "table" and item.id or nil
        if id and allowed[id] and not seen[id] then
            local align = item.align == "right" and "right" or "left"
            out[#out + 1] = { id = id, align = align }
            seen[id] = true
        end
    end
    -- 空列表是用户明确关闭全部组件，不应被当成损坏配置。
    if #out == 0 and #raw > 0 then
        return copyLayout(DEFAULTS[which])
    end
    return out
end

--- 默认布局。
---@param which string
---@return table
function Layout.defaults(which)
    return copyLayout(DEFAULTS[which])
end

--- 当前布局。
---@param which string
---@return table
function Layout.get(which)
    local reader = MoonSettings.get("reader")
    return sanitize(which, reader[KEY[which]])
end

--- 写入布局。
---@param which string
---@param layout table
function Layout.set(which, layout)
    local reader = MoonSettings.get("reader")
    reader[KEY[which]] = sanitize(which, layout)
    MoonSettings.saveSection("reader", reader)
end

--- 是否用月读栏盖住系统栏。
---@param which string
---@return boolean
function Layout.replace(which)
    return MoonSettings.get("reader")[REPLACE_KEY[which]] ~= false
end

--- 写入替代系统栏开关。
---@param which string
---@param on boolean
function Layout.setReplace(which, on)
    local reader = MoonSettings.get("reader")
    reader[REPLACE_KEY[which]] = on ~= false
    MoonSettings.saveSection("reader", reader)
end

--- 组件在布局里的下标；不在返回 nil。
---@param layout table
---@param id string
---@return integer|nil
local function indexOf(layout, id)
    for i = 1, #layout do
        if layout[i].id == id then
            return i
        end
    end
end

--- 组件是否在布局里。
---@param which string
---@param id string
---@return boolean
function Layout.enabled(which, id)
    return indexOf(Layout.get(which), id) ~= nil
end

--- 组件位置与对齐；未启用返回 nil。
---@param which string
---@param id string
---@return number|nil index
---@return string|nil align
function Layout.slot(which, id)
    local layout = Layout.get(which)
    local index = indexOf(layout, id)
    if not index then
        return nil, nil
    end
    return index, layout[index].align
end

--- 开关组件：打开时追加到末尾。
---@param which string
---@param id string
function Layout.toggle(which, id)
    local layout = Layout.get(which)
    local index = indexOf(layout, id)
    if index then
        table.remove(layout, index)
        Layout.set(which, layout)
        return
    end
    if not allowedIds(which)[id] then
        return
    end
    layout[#layout + 1] = { id = id, align = DEFAULT_ALIGN[id] or "left" }
    Layout.set(which, layout)
end

--- 同栏内上下移动。
---@param which string
---@param id string
---@param delta number
function Layout.move(which, id, delta)
    local layout = Layout.get(which)
    local index = indexOf(layout, id)
    if not index then
        return
    end
    local next_index = index + delta
    if next_index < 1 or next_index > #layout then
        return
    end
    layout[index], layout[next_index] = layout[next_index], layout[index]
    Layout.set(which, layout)
end

--- 改左右对齐。
---@param which string
---@param id string
---@param align string
function Layout.setAlign(which, id, align)
    if align ~= "left" and align ~= "right" then
        return
    end
    local layout = Layout.get(which)
    local index = indexOf(layout, id)
    if index then
        layout[index].align = align
        Layout.set(which, layout)
    end
end

return Layout
