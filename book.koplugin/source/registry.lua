--[[--
Source 注册表：单活跃源，候选创建 + 原子激活。
不做静默 fallback。

@module koplugin.book.source.registry
--]]

local MoonSettings = require("utils.settings")
local logger = require("utils.log")
local _ = require("gettext")

--- 简易模板替换（避免测试环境依赖 string.pack）。
---@param fmt string
---@return string
local function T(fmt, a1)
    return (fmt:gsub("%%1", tostring(a1), 1))
end

local Registry = {}

---@type table<SourceId, fun(): table>
local FACTORIES = {
    moon = function() return require("source.moon") end,
    wechat = function() return require("source.wechat") end,
    jdread = function() return require("source.jdread") end,
    copymanga = function() return require("source.copymanga") end,
    fanqie = function() return require("source.fanqie") end,
    ["local"] = function() return require("source.local") end,
}

-- local 排第二：选择器为「混合 → 本地 → 其余在线源」
local ORDER = { "local", "moon", "wechat", "jdread", "copymanga", "fanqie" }

---@type BookSource|nil
local _active = nil
---@type SourceId|nil
local _active_id = nil
---@type table<SourceId, BookSource>
local _resolved = {}

--- 只取 meta，不构造 Source 实例
---@param id SourceId
---@return BookSourceMeta|nil
function Registry.meta(id)
    local fac = FACTORIES[id]
    if not fac then
        return nil
    end
    local ok, mod = pcall(fac)
    if ok and mod and mod.meta then
        return mod.meta()
    end
    return { id = id, name = id }
end

--- 列出数据源元信息。
---@return BookSourceMeta[]
function Registry.list()
    local out = {}
    for _, id in ipairs(ORDER) do
        local meta = Registry.meta(id)
        if meta then
            out[#out + 1] = meta
        end
    end
    return out
end

--- 源是否启用。common.enabled_sources 为 nil = 全部启用；
--- 活跃源恒 true（配置被手改的兜底，picker/设置页都依赖这条）。
---@param id SourceId
---@return boolean
function Registry.isEnabled(id)
    if id == MoonSettings.activeSourceId() then
        return true
    end
    local enabled = MoonSettings.get().enabled_sources
    if type(enabled) ~= "table" then
        return true
    end
    return enabled[id] == true
end

--- 列出启用源元信息（picker 与设置页只显示这些）。
---@return BookSourceMeta[]
function Registry.listEnabled()
    local out = {}
    for _, meta in ipairs(Registry.list()) do
        if Registry.isEnabled(meta.id) then
            out[#out + 1] = meta
        end
    end
    return out
end

--- 启用/禁用源并持久化。禁止禁用活跃源（UI 层也该用 enabled=false 挡住）。
--- 首次写入时以「当前全部启用」初始化集合，保持 nil = 全开的语义边界。
---@param id SourceId
---@param on boolean
---@return boolean ok, string|nil err
function Registry.setEnabled(id, on)
    if not FACTORIES[id] then
        return false, T(_("未知数据源: %1"), id)
    end
    if not on and id == MoonSettings.activeSourceId() then
        return false, _("不能禁用当前使用的数据源")
    end
    local common = MoonSettings.get()
    local enabled = common.enabled_sources
    if type(enabled) ~= "table" then
        enabled = {}
        for _, known in ipairs(ORDER) do
            enabled[known] = true
        end
    else
        local copy = {}
        for k, v in pairs(enabled) do
            copy[k] = v
        end
        enabled = copy
    end
    enabled[id] = on and true or false
    common.enabled_sources = enabled
    MoonSettings.save(common)
    return true
end

--- 按 id 创建数据源实例。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.create(id)
    local fac = FACTORIES[id]
    if not fac then
        return nil, T(_("未知数据源: %1"), id)
    end
    local ok, mod = pcall(fac)
    if not ok then
        logger.warn("book.source require failed", id, mod)
        return nil, T(_("数据源加载失败: %1"), id)
    end
    if not mod or not mod.new then
        return nil, T(_("数据源加载失败: %1"), id)
    end
    return mod.new()
end

--- 关闭源实例；close 抛错只记日志，不能打断替换/失效流程。
---@param src BookSource|nil
local function closeSource(src)
    if src and src.close then
        local ok, err = pcall(src.close, src)
        if not ok then
            logger.warn("source close failed", src.id, err)
        end
    end
end

--- 丢弃当前活跃源缓存并关闭旧实例。
function Registry.invalidate()
    local old = _active
    _active = nil
    _active_id = nil
    closeSource(old)
    for id, source in pairs(_resolved) do
        if source ~= old then closeSource(source) end
        _resolved[id] = nil
    end
end

--- 登录态变更后作废源实例，并通知插件刷新桌面。
---@param plugin table|nil
function Registry.afterAuthChanged(plugin)
    Registry.invalidate()
    if plugin and plugin.onSourceChanged then
        plugin:onSourceChanged()
    end
end

--- 原子替换活跃源
---@param source BookSource
---@param id SourceId
function Registry.activate(source, id)
    local old = _active
    local cached = _resolved[id]
    _resolved[id] = nil
    _active = source
    _active_id = id
    if cached and cached ~= source and cached ~= old then
        closeSource(cached)
    end
    if old and old ~= source then
        closeSource(old)
    end
end

--- 取走非活跃缓存实例（交给调用方激活）；没有则新建。
---@param id SourceId
---@return BookSource|nil, string|nil
local function takeOrCreate(id)
    local cached = _resolved[id]
    _resolved[id] = nil
    if cached then
        return cached
    end
    return Registry.create(id)
end

--- 当前活跃源；不做 fallback。未加载则按配置创建一次。
---@return BookSource|nil, string|nil
function Registry.current()
    local id = MoonSettings.activeSourceId()
    if _active and _active_id == id then
        return _active
    end
    local src, err = takeOrCreate(id)
    if not src then
        return nil, err
    end
    Registry.activate(src, id)
    return _active
end

--- 按书籍身份解析属主源；当前源匹配则复用，否则创建非活跃实例。
--- 不切换用户当前选择的数据源。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.resolve(id)
    local current, err = Registry.current()
    if current and current.id == id then
        return current
    end
    if _resolved[id] then
        return _resolved[id]
    end
    local source, create_err = Registry.create(id)
    if source then _resolved[id] = source end
    return source, create_err or err
end

--- 切换并激活指定数据源。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.setActive(id)
    if not FACTORIES[id] then
        return nil, T(_("未知数据源: %1"), id)
    end
    local candidate, err = takeOrCreate(id)
    if not candidate then
        return nil, err
    end
    local common = MoonSettings.get()
    common.active_source = id
    MoonSettings.save(common)
    Registry.activate(candidate, id)
    logger.info("book.source setActive", id)
    return candidate
end

return Registry
