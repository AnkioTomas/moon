--[[--
Source 注册表：单活跃源

@module koplugin.book.source.registry
--]]

local MoonSettings = require("moon.settings")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Registry = {}

local FACTORIES = {
    moon = function() return require("source.moon") end,
    webdav = function() return require("source.webdav") end,
    wechat = function() return require("source.wechat") end,
    legado = function() return require("source.legado") end,
}

local ORDER = { "moon", "webdav", "wechat", "legado" }

local _active = nil
local _active_id = nil

function Registry.list()
    local out = {}
    for _, id in ipairs(ORDER) do
        local fac = FACTORIES[id]
        if fac then
            local ok, mod = pcall(fac)
            if ok and mod and mod.meta then
                table.insert(out, mod.meta())
            else
                table.insert(out, { id = id, name = id })
            end
        end
    end
    return out
end

function Registry.create(id, cfg)
    local fac = FACTORIES[id]
    if not fac then
        return nil, T(_("未知数据源: %1"), tostring(id))
    end
    local ok, mod = pcall(fac)
    if not ok or not mod or not mod.new then
        return nil, T(_("数据源加载失败: %1"), tostring(id))
    end
    return mod.new(cfg or {})
end

function Registry.invalidate()
    _active = nil
    _active_id = nil
end

--- 按当前配置构造（或返回缓存）活跃源
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
