--[[--
source.registry 第三方源（插件目录下的 moon_source.lua）离线用例

@module tests.source.registry_external_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")

local common = { active_source = "moon" }
package.preload["utils.settings"] = function()
    return {
        get = function() return common end,
        save = function() end,
    }
end

-- 内置源只要 meta / new，别拉真实实现。
local BUILTIN = { "local", "moon", "wechat", "jdread", "copymanga", "fanqie" }
for _idx, id in ipairs(BUILTIN) do
    package.loaded["source." .. id] = {
        meta = function() return { id = id, name = id, type = "book" } end,
        new = function() return { id = id } end,
    }
end

local root = Config.dir() .. "/registry_external"
os.execute("rm -rf '" .. root .. "'")

--- 造一个插件目录；body 为 nil 表示没有描述文件。
---@param name string
---@param body string|nil
---@return table plugin PluginLoader.enabled_plugins 的一项
local function plugin(name, body)
    local path = root .. "/" .. name .. ".koplugin"
    os.execute("mkdir -p '" .. path .. "'")
    if body then
        local f = assert(io.open(path .. "/moon_source.lua", "w"))
        f:write(body)
        f:close()
    end
    return { path = path }
end

local function descriptor(id, extra)
    return ([[
return {
    api = %s,
    meta = function() return { id = %q, name = "Demo", type = "chapter" } end,
    new = function() return { id = %q, created = true } end,
    setting = { open = function() end },
}]]):format(extra or "1", id, id)
end

local enabled = {
        plugin("demo", descriptor("ext.demo")),
        plugin("oldapi", descriptor("ext.old", "2")),
        plugin("noprefix", descriptor("demo")),
        plugin("builtinclash", descriptor("moon")),
        plugin("dup", descriptor("ext.demo")),
        plugin("broken", "error('boom')"),
        plugin("garbage", "return 42"),
}
package.loaded["pluginloader"] = { enabled_plugins = enabled }
package.loaded["source.registry"] = nil
local Registry = require("source.registry")

-- KOReader 正在加载本插件（本插件还不在 enabled_plugins 里）：只给内置源、不缓存；加载完扫一次就缓存。
do
    Assert.eq(#Registry.list(), #BUILTIN, "加载期间不碰第三方描述文件")
    Assert.is_nil(Registry.meta("ext.demo"))
    enabled[#enabled + 1] = Config.selfPlugin()
    Assert.eq(#Registry.list(), #BUILTIN + 1)
    enabled[#enabled + 1] = plugin("after", descriptor("ext.after"))
    Assert.eq(#Registry.list(), #BUILTIN + 1, "插件集合只在重启时变")
    Assert.is_nil(Registry.meta("ext.after"))
end

-- 合法的第三方源排在内置源之后；不合约定的、重名的、加载抛错的全部跳过，内置源不受影响。
do
    local list = Registry.list()
    Assert.eq(#list, #BUILTIN + 1)
    for i, id in ipairs(BUILTIN) do Assert.eq(list[i].id, id) end
    Assert.eq(list[#list].id, "ext.demo")
    Assert.eq(Registry.meta("ext.demo").type, "chapter")
    Assert.is_nil(Registry.meta("ext.old"))
    Assert.is_nil(Registry.meta("demo"))
end

-- create / resolve 走描述表的 new；设置模块挂在描述表上。
do
    local src = Registry.resolve("ext.demo")
    Assert.is_true(src.created)
    Assert.eq(Registry.resolve("ext.demo"), src)
    Assert.eq(type(Registry.external("ext.demo").setting.open), "function")
    Assert.is_nil(Registry.external("moon"))
    Assert.is_nil(Registry.external("ext.old"))
end

-- 已勾选过启用源（集合里没有后装的第三方源）：后装的源默认启用，显式 false 才禁用。
do
    common.enabled_sources = { moon = true, wechat = false }
    Assert.is_true(Registry.isEnabled("ext.demo"))
    Assert.is_false(Registry.isEnabled("wechat"))
    Assert.is_true(Registry.setEnabled("ext.demo", false))
    Assert.is_false(Registry.isEnabled("ext.demo"))
    Assert.is_true(Registry.setEnabled("ext.demo", true))
    Assert.is_true(Registry.isEnabled("ext.demo"))
    common.enabled_sources = nil
end

-- 活跃源可以是第三方源；插件被卸载后 id 不再登记，退回 local。
do
    common.active_source = "ext.demo"
    Assert.eq(Registry.activeId(), "ext.demo")
    common.active_source = "ext.gone"
    Assert.eq(Registry.activeId(), "local")
    local src, err = Registry.create("ext.gone")
    Assert.is_nil(src)
    Assert.eq(type(err), "string")
    common.active_source = "moon"
end

os.execute("rm -rf '" .. root .. "'")
