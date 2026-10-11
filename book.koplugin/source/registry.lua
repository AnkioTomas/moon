--[[--
Source 注册表：源 id 清单、实例缓存（每个 id 一个实例）、活跃源与启用源配置。
活跃源只是配置里的 id，实例与其它源共用同一张缓存表。
不做静默 fallback；唯一例外是已下线的源 id（如 kindle），activeId 退回 local。

@module koplugin.book.source.registry
--]]

local MoonSettings = require("utils.settings")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local Registry = {}

-- 选择器为「混合 → 本地 → 其余在线源」
---@type SourceId[]
local IDS = { "local", "moon", "wechat", "jdread", "copymanga", "fanqie" }
local KNOWN = {}
for _idx, id in ipairs(IDS) do KNOWN[id] = true end

---@type table<SourceId, BookSource>
local instances = {}

--- 持久化的活跃源 id（common.active_source）；未配置或该源已下线时为 "local"。
---@return SourceId
function Registry.activeId()
    local id = MoonSettings.get("source").active_source
    return KNOWN[id] and id or "local"
end

--- 只取 meta，不构造 Source 实例
---@param id SourceId
---@return BookSourceMeta|nil
function Registry.meta(id)
    return KNOWN[id] and require("source." .. id).meta() or nil
end

--- 列出数据源元信息。
---@return BookSourceMeta[]
function Registry.list()
    local out = {}
    for i, id in ipairs(IDS) do
        out[i] = Registry.meta(id)
    end
    return out
end

--- 源是否启用。common.enabled_sources 为 nil = 全部启用；
--- 活跃源恒 true（配置被手改的兜底，picker/设置页都依赖这条）。
---@param id SourceId
---@return boolean
function Registry.isEnabled(id)
    if id == Registry.activeId() then
        return true
    end
    local enabled = MoonSettings.get("source").enabled_sources
    return enabled == nil or enabled[id] == true
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
--- 首次写入时以「当前全部启用」初始化集合，保持 nil = 全开的语义边界。
---@param id SourceId
---@param on boolean
---@return boolean ok, string|nil err
function Registry.setEnabled(id, on)
    if not KNOWN[id] then
        return false, T(_("未知数据源: %1"), id)
    end
    if not on and id == Registry.activeId() then
        return false, _("不能禁用当前使用的数据源")
    end
    local common = MoonSettings.get("source")
    if common.enabled_sources == nil then
        common.enabled_sources = {}
        for _idx, known in ipairs(IDS) do
            common.enabled_sources[known] = true
        end
    end
    common.enabled_sources[id] = on
    MoonSettings.save("source")
    return true
end

--- 按 id 新建数据源实例（不进缓存）。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.create(id)
    if not KNOWN[id] then
        return nil, T(_("未知数据源: %1"), id)
    end
    return require("source." .. id).new()
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
