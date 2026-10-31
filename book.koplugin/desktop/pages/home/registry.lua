--[[--
首页组件注册表。内置组件在前，第三方扩展（source.registry.extensions()，书源与非书源都算）
声明的首页组件按插件加载顺序追加在后。组件来源：provides.home_widgets，旧描述文件为顶层 `home`。

第三方组件两种写法：
  - 完整组件类：继承 desktop.pages.home.base，自带 id / label / icon / createWidget 等。
  - 简写表：{ id, title, build = fun(ctx, w, h): widget, icon?, height? | heightRange?, settings? = fun(desktop, id) }，
    这里包成 base 子类；build 用 ui.themes.widgets.* 拼控件，settings 让编辑态出现设置按钮。
id 按插件划命名空间：必须是 `<插件 id>.` 开头，简写表可只写短名（自动补前缀）；不合规或重名的记日志跳过。

第三方代码全部 pcall 隔离：new / createWidget / heightRange / 生命周期 / showSettings 抛错只记日志，
createWidget 失败画空白占位，绝不拖垮首页。插件卸载或禁用时组件消失、不渲染，但放置表里它的记录在
saveWidgets 时原样保留，重装后回到原位。

@module koplugin.book.desktop.pages.home.registry
--]]

local MoonSettings = require("utils.settings")
local Base = require("desktop.pages.home.base")
local Widgets = require("desktop.pages.home.placements")
local logger = require("utils.log")

---@class BookHomeRegistry
local M = {}

local COMPONENT_MODULES = {
    "clock", "weather", "clock_weather", "weather_forecast", "stats", "tiles", "heatmap", "hitokoto", "excerpt",
    "history", "news",
    "recent_hero", "recent_list", "recent_cards", "random", "shelf",
}

-- 内置书源自带的首页组件：源 id → 组件模块（组件 id 前缀是源 id；旧 ext.<name>. 前缀由 source/legacy_ext 迁移）。
local SOURCE_COMPONENTS = { ["kavita"] = "source.kavita.on_deck" }

---@type BookHomeComponent[]|nil
local components
local by_id = {}

--- 出错时的空白占位：尺寸取布局分配的宽高。
---@param self BookHomeComponent
---@return table
local function blank(self)
    local Geom = require("ui/geometry")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local opts = self.opts or {}
    return WidgetContainer:new{ dimen = Geom:new{ w = opts.width or 1, h = opts.height or 1 } }
end

---@type table<string, fun(self: table, ...): any>
local FALLBACK = {
    createWidget = blank,
    heightRange = function() return { height = 1 } end,
}
local GUARDED = { "createWidget", "heightRange", "onActivate", "onDeactivate", "onDestroy", "onEvent", "showSettings" }

--- 第三方组件类外面包一层：方法都经 pcall，出错记日志并走兜底。
---@param class table
---@param plugin_id string
---@return BookHomeComponent
local function guard(class, plugin_id)
    local G = setmetatable({}, { __index = class })
    G.__index = G
    G.new = function(_self, opts)
        local ok, inst = pcall(class.new, G, opts)
        if ok and type(inst) == "table" then return setmetatable(inst, G) end
        logger.error("desktop.home external new failed", plugin_id, class.id, inst)
        return Base.new(G, opts)
    end
    for _idx, name in ipairs(GUARDED) do
        local fn = class[name]
        if type(fn) == "function" then
            G[name] = function(self, ...)
                local ok, a, b = pcall(fn, self, ...)
                if ok then return a, b end
                logger.error("desktop.home external component error", plugin_id, class.id, name, a)
                local fallback = FALLBACK[name]
                if fallback then return fallback(self, ...) end
            end
        end
    end
    return G
end

--- 简写表包成 base 子类。
---@param spec table
---@param id string
---@return BookHomeComponent
local function fromSpec(spec, id)
    local C = setmetatable({
        id = id,
        label = type(spec.title) == "string" and spec.title or id,
        icon = spec.icon or "widgets",
    }, Base)
    C.__index = C
    function C:createWidget()
        return spec.build(self.ctx, self.opts.width, self.opts.height)
    end
    function C:heightRange(ctx, opts)
        if type(spec.heightRange) == "function" then return spec.heightRange(ctx, opts) end
        return { height = tonumber(spec.height) or math.floor((opts and opts.height or 3) / 3) }
    end
    if type(spec.settings) == "function" then
        function C:showSettings(desktop) spec.settings(desktop, id) end
    end
    return C
end

--- 校验并规范化一个第三方组件声明；不合规返回 nil, 原因。
---@param plugin_id string
---@param item any
---@return BookHomeComponent|nil, string|nil
local function external(plugin_id, item)
    if type(item) ~= "table" then return nil, "not a table" end
    local id = item.id
    if type(id) ~= "string" or id == "" then return nil, "missing id" end
    local prefix = plugin_id .. "."
    local is_class = type(item.createWidget) == "function"
    if not is_class and not id:find("^ext%.") then id = prefix .. id end
    if id:sub(1, #prefix) ~= prefix or #id == #prefix then return nil, "id must start with " .. prefix end
    if by_id[id] then return nil, "duplicate id " .. id end
    if is_class then return guard(item, plugin_id) end
    if type(item.build) ~= "function" then return nil, "build() or createWidget() required" end
    return guard(fromSpec(item, id), plugin_id)
end

--- 全部组件定义，首次使用时收集：第三方组件来自源注册表，KOReader 加载插件期间还扫不全。
---@return BookHomeComponent[]
function M.list()
    if components then return components end
    components = {}
    for _idx, name in ipairs(COMPONENT_MODULES) do
        local component = require("desktop.pages.home." .. name)
        components[#components + 1] = component
        by_id[component.id] = component
    end
    for source_id, modname in pairs(SOURCE_COMPONENTS) do
        local component, why = external(source_id, require(modname))
        if component then
            components[#components + 1] = component
            by_id[component.id] = component
        else
            logger.error("desktop.home source component rejected", source_id, why)
        end
    end
    for _idx, ext in ipairs(require("source.registry").extensions()) do
        for _cidx, item in ipairs(ext.home_widgets or {}) do
            local component, why = external(ext.id, item)
            if component then
                components[#components + 1] = component
                by_id[component.id] = component
            else
                logger.error("desktop.home external component rejected", ext.id,
                    type(item) == "table" and item.id, why)
            end
        end
    end
    return components
end

--- 按 id 查找组件定义。
---@param id string|nil
---@return BookHomeComponent|nil
function M.find(id)
    M.list()
    return id and by_id[id] or nil
end

--- 当前钉页放置表（已净化）。
---@return BookHomeWidgetPlacement[]
function M.widgets()
    return Widgets.load(M.list())
end

--- 写回放置表。
---@param list BookHomeWidgetPlacement[]
function M.saveWidgets(list)
    list = Widgets.compactPages(list)
    -- 暂时缺席（插件卸载 / 禁用）的第三方组件记录原样留着，重装后回到原位。
    local saved = MoonSettings.get("desktop.pages.home").home_widgets
    if type(saved) == "table" then
        local keep = {}
        for _idx, item in ipairs(list) do keep[item.id] = true end
        for _idx, item in ipairs(saved) do
            local id = type(item) == "table" and item.id
            if type(id) == "string" and id:find("^ext%.") and not keep[id] and not M.find(id) then
                keep[id] = true
                list[#list + 1] = item
            end
        end
    end
    Widgets.save(list)
end

--- 读取并净化用户启用的有序组件 id 列表（全局 page/order）。
---@return string[]
function M.enabledLayout()
    return Widgets.ids(M.widgets())
end

--- 是否尚未按真实屏幕高度生成首页布局。
---@return boolean
function M.needsLayout()
    return MoonSettings.get("desktop.pages.home").home_widgets == nil
end

return M
