--[[--
Source 注册表：源 id 清单、实例缓存（每个 id 一个实例）、活跃源与启用源配置。
活跃源只是配置里的 id，实例与其它源共用同一张缓存表。
不做静默 fallback；唯一例外是当前不可用的源 id（如不在 Kindle 上的 kindle，或卸载了的第三方源），activeId 退回 local。

第三方源：任何已启用的 KOReader 插件根目录里放 `moon_source.lua` 即登记一个源（契约见 examples/moonsource-demo.koplugin/moon_source.lua），
按 PluginLoader.enabled_plugins 扫描，排在内置源之后；插件全部加载完后才缓存扫描结果。

描述文件不合约定（api ~= Registry.API、缺 meta/new、id 不是 ext.<name>、与已登记 id 重名、加载抛错）或 new() 抛错：
记错误日志并跳过，第三方代码不拖垮内置源。enabled_sources 为 nil 或集合里没有的 id 算启用，只有显式 false 是禁用；活跃源不能禁用。
resolve(id) 取书的属主实例，不改活跃源（打开旧书不串源的关键）；登录态或连接配置变了用 reload()。

@module koplugin.book.source.registry
--]]

local MoonSettings = require("utils.settings")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local Registry = {}

--- 第三方源描述文件的契约版本，不相等即拒绝加载。
Registry.API = 1
local DESCRIPTOR = "moon_source.lua"

-- 选择器为「混合 → 本地 → 其余在线源 → 第三方源」
---@type SourceId[]
local BUILTIN = { "local", "moon", "wechat", "jdread", "copymanga", "fanqie" }

---@type SourceId[]|nil
local ids
---@type table<SourceId, boolean>
local known = {}
---@type table<SourceId, table> 第三方源 id → 描述表 { api, meta, new, setting? }
local external = {}

---@type table<SourceId, BookSource>
local instances = {}

--- 读一个第三方描述文件，不合约定就抛错。
---@param path string
---@return SourceId id, table desc
local function readDescriptor(path)
    local desc = dofile(path)
    assert(type(desc) == "table" and desc.api == Registry.API, "api mismatch, want " .. Registry.API)
    assert(type(desc.meta) == "function" and type(desc.new) == "function", "meta() and new() required")
    local id = desc.meta().id
    assert(type(id) == "string" and id:match("^ext%.[%w_%-]+$"), "id must look like ext.<name>")
    return id, desc
end

--- 本插件根目录，与 PluginLoader 给的 plugin.path 同一字符串（模块经 `<plugin.path>/?.lua` 加载）。
local PLUGIN_ROOT = debug.getinfo(1, "S").source:match("^@(.*)/source/registry%.lua$")

--- KOReader 已加载完全部插件：本插件进 enabled_plugins 是在 dofile 本插件 main.lua 之后，
--- 在那之前排在后面的插件还没加载，package.path 上也只有本插件目录。
---@param plugins table[]
---@return boolean
local function pluginsLoaded(plugins)
    for _idx, plugin in ipairs(plugins) do
        if plugin.path == PLUGIN_ROOT then return true end
    end
    return false
end

--- 源 id 清单：内置在前，第三方按插件加载顺序在后。插件集合只在重启时变，加载完扫一次即可；
--- 加载期间（本插件顶层模块被 require 时）只给内置源、不缓存。
---@return SourceId[]
local function sourceIds()
    if ids then return ids end
    local list, seen, ext = {}, {}, {}
    for i, id in ipairs(BUILTIN) do
        list[i] = id
        seen[id] = true
    end
    -- Kindle 书库只在有系统 cc.db 且装了 kindle.koplugin 时出现，排在内置源末尾。
    if require("source.kindle").available() then
        list[#list + 1] = "kindle"
        seen.kindle = true
    end
    local plugins = require("pluginloader").enabled_plugins
    if not pluginsLoaded(plugins) then
        known, external = seen, ext
        return list
    end
    local lfs = require("libs/libkoreader-lfs")
    for _idx, plugin in ipairs(plugins) do
        local path = plugin.path .. "/" .. DESCRIPTOR
        if lfs.attributes(path, "mode") == "file" then
            -- 第三方代码不归月读管：坏一个只记日志跳过，不能拖垮内置源和整个桌面。
            local ok, id, desc = pcall(readDescriptor, path)
            if not ok then
                logger.err("book.source external rejected", path, id)
            elseif seen[id] then
                logger.err("book.source external duplicate id", path, id)
            else
                list[#list + 1] = id
                seen[id] = true
                ext[id] = desc
            end
        end
    end
    ids, known, external = list, seen, ext
    return ids
end

--- 源门面模块：第三方是描述表，内置按模块名加载。
---@param id SourceId
---@return table
local function sourceModule(id)
    return external[id] or require("source." .. id)
end

--- 第三方源的描述表；内置源与未知 id 返回 nil。
---@param id SourceId
---@return table|nil
function Registry.external(id)
    sourceIds()
    return external[id]
end

--- 持久化的活跃源 id（common.active_source）；未配置或该源已下线时为 "local"。
---@return SourceId
function Registry.activeId()
    sourceIds()
    local id = MoonSettings.get("source").active_source
    return known[id] and id or "local"
end

--- 只取 meta，不构造 Source 实例
---@param id SourceId
---@return BookSourceMeta|nil
function Registry.meta(id)
    sourceIds()
    return known[id] and sourceModule(id).meta() or nil
end

--- 列出数据源元信息。
---@return BookSourceMeta[]
function Registry.list()
    local out = {}
    for i, id in ipairs(sourceIds()) do
        out[i] = Registry.meta(id)
    end
    return out
end

--- 源是否启用。common.enabled_sources 为 nil 或集合里没有这个 id（后装的源）= 启用；
--- 活跃源恒 true（配置被手改的兜底，picker/设置页都依赖这条）。
---@param id SourceId
---@return boolean
function Registry.isEnabled(id)
    if id == Registry.activeId() then
        return true
    end
    local enabled = MoonSettings.get("source").enabled_sources
    return enabled == nil or enabled[id] ~= false
end

--- 列出启用源元信息（picker 与设置页只显示这些）。
---@return BookSourceMeta[]
function Registry.listEnabled()
    local out = {}
    for _idx, meta in ipairs(Registry.list()) do
        if Registry.isEnabled(meta.id) then
            out[#out + 1] = meta
        end
    end
    return out
end

--- 启用/禁用源并持久化。禁止禁用活跃源（UI 层也该用 enabled=false 挡住）。
---@param id SourceId
---@param on boolean
---@return boolean ok, string|nil err
function Registry.setEnabled(id, on)
    sourceIds()
    if not known[id] then
        return false, T(_("未知数据源: %1"), id)
    end
    if not on and id == Registry.activeId() then
        return false, _("不能禁用当前使用的数据源")
    end
    local common = MoonSettings.get("source")
    common.enabled_sources = common.enabled_sources or {}
    common.enabled_sources[id] = on
    MoonSettings.save("source")
    return true
end

--- 按 id 新建数据源实例（不进缓存）。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.create(id)
    sourceIds()
    if not known[id] then
        return nil, T(_("未知数据源: %1"), id)
    end
    local mod = sourceModule(id)
    if not external[id] then return mod.new() end
    -- 第三方源的 new() 抛错不能拖垮书库 / 桌面：记日志，按源不可用处理。
    local ok, source, err = pcall(mod.new)
    if not ok then
        logger.err("book.source external new failed", id, source)
        return nil, T(_("数据源初始化失败: %1"), id)
    end
    return source, err
end

--- 关闭并丢弃全部缓存实例（下次 resolve / current 按新配置重建）。
function Registry.invalidate()
    for id, source in pairs(instances) do
        instances[id] = nil
        source:close()
    end
end

--- 源配置变了（换源、混合模式、书城开关、OPDS 地址等）：广播 SourceChanged，由桌面重建各页。
--- 同步广播到整个窗口栈；桌面没开时没人处理，本来就无事可做。
function Registry.notifyChanged()
    require("ui/uimanager"):broadcastEvent(require("ui/event"):new("SourceChanged"))
end

--- 登录态或连接配置变了：作废源实例（下次 current() 按新配置重建），再通知桌面。
function Registry.reload()
    Registry.invalidate()
    Registry.notifyChanged()
end

--- 按 id 取源实例（缓存复用，首次创建）。阅读与书籍操作按书的属主源解析，不切换活跃源。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.resolve(id)
    if instances[id] then
        return instances[id]
    end
    local source, err = Registry.create(id)
    instances[id] = source
    return source, err
end

--- 当前活跃源。
---@return BookSource|nil, string|nil
function Registry.current()
    return Registry.resolve(Registry.activeId())
end

--- 切换并激活指定数据源。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.setActive(id)
    local source, err = Registry.resolve(id)
    if not source then
        return nil, err
    end
    MoonSettings.get("source").active_source = id
    MoonSettings.save("source")
    logger.info("book.source setActive", id)
    return source
end

return Registry
