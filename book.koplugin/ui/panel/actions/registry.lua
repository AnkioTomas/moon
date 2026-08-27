--[[-- 快捷动作注册表：内置动作加载与调度辅助。
@module koplugin.book.ui.panel.actions.registry
--]]

require("l10n").apply()

local logger = require("logger")

---@class BookQuickPanelRegistry
---@field get fun(id: string): BookQuickPanelAction|nil
---@field desktopOrder fun(): string[]
---@field available fun(action: BookQuickPanelAction|nil, ctx: BookQuickPanelContext|nil): boolean
---@field active fun(id: string, action: BookQuickPanelAction|nil, ctx: BookQuickPanelContext|nil): boolean

local Registry = {}

local DESKTOP_ORDER = {
    "night", "wifi", "remote", "rotate", "refresh", "screenshot", "frontlight", "suspend",
}
local READER_ORDER = {
    "toc", "highlights", "xray", "preset", "dictionary",
}

local builtins = {}
local loaded = false

--- 快捷动作上下文，阅读页动作从这里拿 ReaderUI。
---@class BookQuickPanelContext
---@field ui table|nil

--- 快捷动作契约，注册表只依赖这些字段调度。
---@class BookQuickPanelAction
---@field id string
---@field title string
---@field icon string
---@field active_icon string|nil
---@field fixed boolean|nil
---@field scope "desktop"|"reader"
---@field event string|nil
---@field keep_open boolean|nil
---@field refresh_delay number|nil
---@field available nil|fun(ctx: BookQuickPanelContext|nil): boolean|nil
---@field active nil|fun(ctx: BookQuickPanelContext|nil): boolean|nil
---@field run nil|fun(ctx: BookQuickPanelContext)

--- 一次性加载桌面和阅读页内置动作。
---@return void
local function ensureLoaded()
    if loaded then return end
    loaded = true
    for _, id in ipairs(DESKTOP_ORDER) do
        builtins[id] = require("ui.panel.actions.desktop." .. id)
    end
    for _, id in ipairs(READER_ORDER) do
        builtins[id] = require("ui.panel.actions.reader." .. id)
    end
end

--- 取注册的内置动作；未注册返回 nil。
---@param id string
---@return BookQuickPanelAction|nil
function Registry.get(id)
    ensureLoaded()
    return builtins[id]
end

--- 桌面动作设置页顺序。
---@return string[]
function Registry.desktopOrder()
    return { unpack(DESKTOP_ORDER) }
end

--- 阅读页动作顺序。
---@return string[]
function Registry.readerOrder()
    return { unpack(READER_ORDER) }
end

---@param action BookQuickPanelAction|nil
---@param ctx BookQuickPanelContext|nil
---@return boolean
function Registry.available(action, ctx)
    if not action then return false end
    if not action.available then return true end
    local ok, result = pcall(action.available, ctx)
    if not ok then
        logger.err("book quick panel action availability failed:", result)
        return false
    end
    return result == true
end

--- 调用动作激活态检查，并捕获异常。
---@param id string
---@param action BookQuickPanelAction|nil
---@param ctx BookQuickPanelContext|nil
---@return boolean
function Registry.active(id, action, ctx)
    if not action or not action.active then return false end
    local ok, result = pcall(action.active, ctx)
    if not ok then
        logger.err("book quick panel action state failed:", id, result)
        return false
    end
    return result == true
end

---@type BookQuickPanelRegistry
return Registry
