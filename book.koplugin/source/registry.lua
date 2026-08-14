--[[--
Source 注册表：单活跃源，候选创建 + 原子激活。
不做静默 fallback。

@module koplugin.book.source.registry
--]]

local MoonSettings = require("utils.settings")
local logger = require("logger")
local _ = require("gettext")

--- 简易模板替换（避免测试环境依赖 string.pack）。
---@param fmt string
---@param a1 any
---@param a2 any
---@param a3 any
---@return string
local function T(fmt, a1, a2, a3)
    local s = tostring(fmt)
    if a1 ~= nil then s = s:gsub("%%1", tostring(a1), 1) end
    if a2 ~= nil then s = s:gsub("%%2", tostring(a2), 1) end
    if a3 ~= nil then s = s:gsub("%%3", tostring(a3), 1) end
    return s
end

local Registry = {}

---@type table<SourceId, fun(): table>
local FACTORIES = {
    moon = function() return require("source.moon") end,
    webdav = function() return require("source.webdav") end,
    wechat = function() return require("source.wechat") end,
    ["local"] = function() return require("source.local") end,
}

-- 正式源（WebDAV 已具备列目录+下载）
local ORDER = { "moon", "wechat", "webdav", "local" }
local PREVIEW_ORDER = {}

---@type BookSource|nil
local _active = nil
---@type SourceId|nil
local _active_id = nil

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

--- 列出正式数据源元信息。
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

--- 列出预览数据源元信息。
---@return BookSourceMeta[]
function Registry.listPreview()
    local out = {}
    for _, id in ipairs(PREVIEW_ORDER) do
        local meta = Registry.meta(id)
        if meta then
            meta.preview = true
            out[#out + 1] = meta
        end
    end
    return out
end

--- 按 id 创建数据源实例。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.create(id)
    local fac = FACTORIES[id]
    if not fac then
        return nil, T(_("未知数据源: %1"), tostring(id))
    end
    local ok, mod = pcall(fac)
    if not ok then
        logger.warn("book.source require failed", id, mod)
        return nil, T(_("数据源加载失败: %1"), tostring(id))
    end
    if not mod or not mod.new then
        return nil, T(_("数据源加载失败: %1"), tostring(id))
    end
    return mod.new()
end

--- 创建候选；失败不改动当前活跃源
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.createCandidate(id)
    return Registry.create(id)
end

--- 安全关闭源实例（忽略 close 异常）。
---@param src BookSource|nil
local function closeSource(src)
    if src and src.close then
        pcall(function()
            src:close()
        end)
    end
end

--- 丢弃当前活跃源缓存并关闭旧实例。
function Registry.invalidate()
    local old = _active
    _active = nil
    _active_id = nil
    closeSource(old)
end

--- 原子替换活跃源
---@param source BookSource
---@param id SourceId
function Registry.activate(source, id)
    local old = _active
    _active = source
    _active_id = id
    if old and old ~= source then
        closeSource(old)
    end
end

--- 当前活跃源；不做 fallback。未加载则按配置创建一次。
---@return BookSource|nil, string|nil
function Registry.current()
    local id = MoonSettings.activeSourceId()
    if _active and _active_id == id then
        return _active
    end
    local src, err = Registry.create(id)
    if not src then
        return nil, err
    end
    Registry.activate(src, id)
    return _active
end

--- 必须拿到活跃源；失败抛错给调用方处理（不再静默换 Moon）
---@return BookSource
function Registry.requireActive()
    local src, err = Registry.current()
    if not src then
        error(err or "no active source")
    end
    return src
end

--- 旧名：返回当前源或 nil，不做 fallback、不抛错。
---@return BookSource|nil
function Registry.getActive()
    local src = Registry.current()
    return src
end

--- 切换并激活指定数据源。
---@param id SourceId
---@return BookSource|nil, string|nil
function Registry.setActive(id)
    if not FACTORIES[id] then
        return nil, T(_("未知数据源: %1"), tostring(id))
    end
    local candidate, err = Registry.createCandidate(id)
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

--- 插件关闭时释放活跃源。
function Registry.shutdown()
    Registry.invalidate()
end

return Registry
