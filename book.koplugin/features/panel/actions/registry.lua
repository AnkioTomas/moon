--[[-- 快捷动作注册表：内置动作加载与调度辅助。
第三方扩展的开关（Features.external("panel")）追加在内置 feature 之后：id 自动加 `<扩展 id>.` 前缀，
回调经 Features.wrap 隔离；缺字段、未知 scope、撞名只记日志跳过。插件还没加载完时不缓存，下次重收。
已保存但插件已卸载的 id，get 返回 nil、available 为假，列表静默跳过。
@module koplugin.book.features.panel.actions.registry
--]]

require("l10n").apply()

---@class BookQuickPanelRegistry
---@field get fun(id: string): BookQuickPanelAction|nil
---@field desktopOrder fun(): string[]
---@field available fun(action: BookQuickPanelAction|nil, ctx: BookQuickPanelContext|nil): boolean
---@field active fun(action: BookQuickPanelAction, ctx: BookQuickPanelContext|nil): boolean
---@field execute fun(action: BookQuickPanelAction, ctx: BookQuickPanelContext, opts: BookQuickPanelExecuteOpts|nil)

local Registry = {}

-- 内置动作只放 KOReader 原生能力与核心阅读会话（actions/<scope>/<id>.lua）。
-- 属于某个 feature 的开关一律写在 features/<name>/panel.lua，扫描后追加到对应 scope 末尾（按目录名）。
local DESKTOP_ORDER = {
    "night", "wifi", "rotate", "refresh", "screenshot", "frontlight", "suspend",
}
local READER_ORDER = {
    "toc", "font", "highlights", "bookorbit", "push_progress", "pull_progress",
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
            if not action.run and not action.event then
                error("feature " .. name .. " panel: action needs run or event")
            end
            out[#out + 1] = action
        end
    end
    return out
end

--- 第三方扩展的开关：校验、加前缀、包隔离；不合格记日志跳过。
---@return BookQuickPanelAction[] actions, boolean ready
local function externalActions()
    local Features = require("features")
    local logger = require("utils.log")
    local out = {}
    local items, ready = Features.external("panel")
    for _idx, ext in ipairs(items) do
        local actions = Features.try(ext.id .. " panel", ext.mod.actions)
        if type(actions) ~= "table" or actions.id or actions.scope then
            logger.err("feature external panel rejected: actions must return a list", ext.id)
            actions = {}
        end
        for _i, raw in ipairs(actions) do
            local id = type(raw) == "table" and Features.prefix(ext.id, raw.id)
            local why = not id and "action needs id"
                or not SCOPES[raw.scope] and "unknown scope " .. tostring(raw.scope)
                or not (raw.title and raw.icon) and "action needs title and icon"
                or not (raw.run or raw.event) and "action needs run or event"
            if why then
                logger.err("feature external panel rejected", ext.id, why)
            else
                local label = "quick action " .. id
                local action = {}
                for key, value in pairs(raw) do action[key] = value end
                action.id = id
                action.run = Features.wrap(label, raw.run)
                action.available = Features.wrap(label, raw.available)
                action.active = Features.wrap(label, raw.active)
                out[#out + 1] = action
            end
        end
    end
    return out, ready
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
    local ext_actions, ready = externalActions()
    for _idx, action in ipairs(ext_actions) do
        if builtin_map[action.id] or extra_map[action.id] then
            require("utils.log").err("feature external panel rejected: duplicate id", action.id)
        else
            extra_map[action.id] = action
            local bucket = action.scope == "reader" and read or desk
            bucket[#bucket + 1] = action.id
        end
    end
    builtins, extra, extra_desktop, extra_reader = builtin_map, extra_map, desk, read
    loaded = ready
end

--- 内置顺序后面接上该 scope 的 feature 开关。
---@param base string[]
---@param feature_ids string[]
---@return string[]
local function withFeatures(base, feature_ids)
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
    return not action.available or action.available(ctx) == true
end

---@param action BookQuickPanelAction
---@param ctx BookQuickPanelContext|nil
---@return boolean
function Registry.active(action, ctx)
    return action.active ~= nil and action.active(ctx) == true
end

--- 执行动作：非 keep_open 先关面板；keep_open 的下一 tick（或 refresh_delay 秒后）刷新面板。
--- 关掉的面板不能再刷新：updateItems 会在已关闭的菜单上重建内容并多刷一次墨水屏。
---@param action BookQuickPanelAction
---@param ctx BookQuickPanelContext
---@param opts BookQuickPanelExecuteOpts|nil
function Registry.execute(action, ctx, opts)
    local UIManager = require("ui/uimanager")
    opts = opts or {}
    if not action.keep_open and opts.close then opts.close() end
    if action.run then
        -- 非触屏设备由原生菜单项回调直接调到这里，不经面板的 guard。
        require("ui.guard").call("quick action " .. tostring(action.id), action.run, ctx)
    else
        UIManager:broadcastEvent(require("ui/event"):new(action.event))
    end
    if not action.keep_open or not opts.refresh then return end
    if action.refresh_delay then
        UIManager:scheduleIn(action.refresh_delay, opts.refresh)
    else
        UIManager:nextTick(opts.refresh)
    end
end

---@type BookQuickPanelRegistry
return Registry
