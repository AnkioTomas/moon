--[[--
Source 注册表：单活跃源

@module koplugin.book.source.registry
--]]

local MoonSettings = require("moon.settings")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Registry = {}

---@type table<MoonSourceId, fun(): table>
local FACTORIES = {
    moon = function() return require("source.moon") end,
    webdav = function() return require("source.webdav") end,
    wechat = function() return require("source.wechat") end,
    legado = function() return require("source.legado") end,
}

local ORDER = { "moon", "webdav", "wechat", "legado" }

---@type BookSource|nil
local _active = nil
---@type MoonSourceId|nil
local _active_id = nil

--- 只取 meta，不构造 Source 实例
---@param id MoonSourceId
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

---@return BookSourceMeta[]
function Registry.list()
    local out = {}
    for _, id in ipairs(ORDER) do
        local meta = Registry.meta(id)
        if meta then
            table.insert(out, meta)
        end
    end
    return out
end

---@param id MoonSourceId
---@param cfg MoonSourceConfig|table|nil
---@return BookSource|nil, string|nil
function Registry.create(id, cfg)
    local fac = FACTORIES[id]
    if not fac then
        return nil, T(_("未知数据源: %1"), tostring(id))
    end
    local ok, mod = pcall(fac)
    if not ok then
        -- 以前吞掉 pcall 错误，日志里只剩「加载失败」看不出 module not found
        logger.warn("book.source require failed", id, mod)
        return nil, T(_("数据源加载失败: %1"), tostring(id))
    end
    if not mod or not mod.new then
        return nil, T(_("数据源加载失败: %1"), tostring(id))
    end
    return mod.new(cfg or {})
end

function Registry.invalidate()
    _active = nil
    _active_id = nil
end

--- 按当前配置构造（或返回缓存）活跃源
---@return BookSource|nil
function Registry.getActive()
    local id = MoonSettings.activeSourceId()
    if _active and _active_id == id then
        return _active
    end
    local cfg = MoonSettings.getSource(id)
    local src, err = Registry.create(id, cfg)
    if not src then
        logger.warn("book.source getActive failed", id, err)
        if id ~= "moon" then
            src = Registry.create("moon", MoonSettings.getSource("moon"))
            id = "moon"
        end
    end
    _active = src
    _active_id = id
    return _active
end

---@param id MoonSourceId
---@return BookSource|nil, string|nil
function Registry.setActive(id)
    if not FACTORIES[id] then
        return nil, T(_("未知数据源: %1"), tostring(id))
    end
    local common = MoonSettings.get()
    common.active_source = id
    MoonSettings.save(common)
    Registry.invalidate()
    return Registry.getActive()
end

return Registry
