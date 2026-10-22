--[[-- 书籍详情子模块。 @module desktop.detail --]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Text = require("ui.themes.widgets.text")
local SourceCapabilities = require("source.base").SourceCapabilities


local M = {}

-- 书城条目的 source_id 对应后端模块 `store.<id>.init`，不是 BookSource。
local STORES = { zlib = true, opds = true }

--- 书城预览书的后端门面；库内书返回 nil。
---@param book table
---@return table|nil
function M.storeBackend(book)
    local id = book.source_id
    return STORES[id] and require("store." .. id) or nil
end

--- 书籍属主源：身份匹配当前源则复用，否则按 source_id 解析。
---@param book table 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return table|nil
function M.bookOwnerSource(book, fallback_source)
    if not book.source_id then return fallback_source end
    return require("source.registry").resolve(book.source_id) or fallback_source
end

--- 按书籍属主源判断是否可刮削（不用当前活跃源冒充）。
---@param book table 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return boolean
function M.bookSupportsScrape(book, fallback_source)
    if not (book.source_id and book.stable_id) then return false end
    return SourceCapabilities.supportsScrape(M.bookOwnerSource(book, fallback_source))
end

--- 按书籍属主源判断是否可编辑元信息。
---@param book table 当前操作或展示的书籍数据
---@param fallback_source table|nil 书籍未提供源标识时使用的数据源
---@return boolean
function M.bookSupportsEdit(book, fallback_source)
    if not (book.source_id and book.stable_id) then return false end
    return SourceCapabilities.supportsEdit(M.bookOwnerSource(book, fallback_source))
end

--- 小节标题（简介等）。
---@param text string 需要展示的文字
---@param width number 目标宽度，单位像素
---@return table
function M.sectionTitle(text, width)
    return Text.line("body", text, { width = width, bold = true })
end

--- KPI 卡片：卡片表面，上值下标签。
---@param w number 可用宽度，单位像素
---@param value string 数值文案
---@param label string 展示给用户的标签文字
---@param bg_alpha number|nil 卡片底色不透明度百分比，缺省 100
---@return table, number 卡片 widget 与其高度
function M.kpiCard(w, value, label, bg_alpha)
    local t = Theme.current()
    local pad = Theme.px(t.space.sm)
    local inner = math.max(1, w - pad * 2)
    local card = Box:new{
        style = t.card,
        bg_alpha = bg_alpha,
        width = w,
        padding = pad,
        VerticalGroup:new{
            align = "center",
            Text.line("title", value, { width = inner }),
            VerticalSpan:new{ width = Theme.px(t.space.xs) },
            Text.line("caption", label, { width = inner, color = t.color.muted }),
        },
    }
    return card, card:getSize().h
end


return M
