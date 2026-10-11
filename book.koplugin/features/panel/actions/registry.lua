--[[-- 快捷动作注册表：内置动作加载与调度辅助。
@module koplugin.book.features.panel.actions.registry
--]]

require("l10n").apply()

local logger = require("utils.log")

---@class BookQuickPanelRegistry
---@field get fun(id: string): BookQuickPanelAction|nil
---@field desktopOrder fun(): string[]
---@field available fun(action: BookQuickPanelAction|nil, ctx: BookQuickPanelContext|nil): boolean
---@field active fun(id: string, action: BookQuickPanelAction|nil, ctx: BookQuickPanelContext|nil): boolean

local Registry = {}

-- 内置动作。feature 的开关不写在这里，扫描 features/<name>/panel.lua 追加到对应 scope 末尾（按目录名）。
local DESKTOP_ORDER = {
    "night", "wifi", "rotate", "refresh", "screenshot", "frontlight", "autolight", "suspend",
}
local READER_ORDER = {
    "toc", "font", "highlights", "bookorbit", "xray", "xray_refresh",
}

local builtins = {}
local extra = {}
local extra_desktop = {}
local extra_reader = {}
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

local SCOPES = { desktop = true, reader = true }

--- 扫描 features/*/panel.lua 收集开关（按目录名排序）；非法 scope、缺字段、单条误返回直接报错。
---@return BookQuickPanelAction[]
local function featureActions()
    local out = {}
    for _idx, name in ipairs(require("features").scan("panel")) do
        local actions = require("features." .. name .. ".panel").actions()
        -- 单条也必须是数组。误返回一条动作表时不能静默丢掉。
        if type(actions) ~= "table" or actions.id or actions.scope then
            error("feature " .. name .. " panel: actions must return a list")
        end
        for _i, action in ipairs(actions) do
            if type(action) ~= "table" or type(action.id) ~= "string" or action.id == "" then
                error("feature " .. name .. " panel: action needs id")
            end
            if not SCOPES[action.scope] then
                error("feature " .. name .. " panel: unknown scope " .. tostring(action.scope))
            end
            if not action.title or not action.icon then
                error("feature " .. name .. " panel: action needs title and icon")
            end
            out[#out + 1] = action
        end
    end
    return out
end

--- 一次性加载内置动作，再追加 feature 开关。失败不置 loaded，下次重试不会叠一份。
local function ensureLoaded()
    if loaded then return end
    local builtin_map = {}
    for _idx, id in ipairs(DESKTOP_ORDER) do
        builtin_map[id] = require("features.panel.actions.desktop." .. id)
    end
    for _idx, id in ipairs(READER_ORDER) do
        builtin_map[id] = require("features.panel.actions.reader." .. id)
    end
    local extra_map, desk, read = {}, {}, {}
    for _idx, action in ipairs(featureActions()) do
        if builtin_map[action.id] or extra_map[action.id] then
            error("quick panel action id already registered: " .. action.id)
        end
        extra_map[action.id] = action
        local bucket = action.scope == "reader" and read or desk
        bucket[#bucket + 1] = action.id
    end
    builtins, extra, extra_desktop, extra_reader = builtin_map, extra_map, desk, read
    loaded = true
end

--- 内置顺序后面接上该 scope 的 feature 开关。
---@param base string[]
---@param feature_ids string[]
---@return string[]
local function withFeatures(base, feature_ids)
    ensureLoaded()
    local order = { unpack(base) }
    for _idx, id in ipairs(feature_ids) do
        order[#order + 1] = id
    end
    return order
end

--- 取注册的动作；未注册返回 nil。
---@param id string
---@return BookQuickPanelAction|nil
function Registry.get(id)
    ensureLoaded()
    return builtins[id] or extra[id]
end

--- 桌面动作设置页顺序：内置项，然后是 feature 开关。
--- 先加载再读 extra_*：参数在调用前求值，不能把加载放进 withFeatures。
---@return string[]
function Registry.desktopOrder()
    ensureLoaded()
    return withFeatures(DESKTOP_ORDER, extra_desktop)
end

--- 阅读页动作顺序：内置项，然后是 feature 开关。
---@return string[]
function Registry.readerOrder()
    ensureLoaded()
    return withFeatures(READER_ORDER, extra_reader)
end

---@param action BookQuickPanelAction|nil
---@param ctx BookQuickPanelContext|nil
---@return boolean
function Registry.available(action, ctx)
    if not action then return false end
    if not action.available then return true end
    local ok, result = pcall(action.available, ctx)
    if not ok then
        logger.error("book quick panel action availability failed:", result)
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
        logger.error("book quick panel action state failed:", id, result)
        return false
    end
    return result == true
end

---@type BookQuickPanelRegistry
return Registry
