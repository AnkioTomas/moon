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
local BUILTIN = { "local", "moon", "wechat", "jdread", "copymanga", "fanqie", "qimao", "legado", "jjwxc", "qidian", "qqreader", "iread" }
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
        -- 自己声明能力：非书源扩展不要 meta/new，id 写在顶层；provides 里不写 source 就不是书源
        plugin("widgets", [[return { api = 1, id = "ext.widgets", provides = { source = false, home_widgets = { { id = "w" } }, features = { panel = "x.panel" } } }]]),
        plugin("implicit", [[return { api = 1, id = "ext.implicit", provides = { home_widgets = {} } }]]),
        plugin("declared", [[return { api = 1, provides = { source = true, home_widgets = { { id = "d" } } },
            meta = function() return { id = "ext.declared", name = "D", type = "book" } end,
            new = function() return { id = "ext.declared" } end }]]),
        plugin("srcnometa", [[return { api = 1, id = "ext.srcnometa", provides = { source = true } }]]),
        plugin("legacyoff", [[return { api = 1, id = "ext.legacyoff", source = false, home = { { id = "l" } } }]]),
        plugin("widgetclash", [[return { api = 1, id = "ext.demo", provides = { source = false } }]]),
}
package.loaded["pluginloader"] = { enabled_plugins = enabled }
package.loaded["source.registry"] = nil
local Registry = require("source.registry")

-- KOReader 正在加载本插件（本插件还不在 enabled_plugins 里）：只给内置源、不缓存；加载完扫一次就缓存。
do
    Assert.eq(#Registry.list(), #BUILTIN, "加载期间不碰第三方描述文件")
    Assert.is_nil(Registry.meta("ext.demo"))
    enabled[#enabled + 1] = Config.selfPlugin()
    Assert.eq(#Registry.list(), #BUILTIN + 2)
    enabled[#enabled + 1] = plugin("after", descriptor("ext.after"))
    Assert.eq(#Registry.list(), #BUILTIN + 2, "插件集合只在重启时变")
    Assert.is_nil(Registry.meta("ext.after"))
end

-- 合法的第三方源排在内置源之后；不合约定的、重名的、加载抛错的全部跳过，内置源不受影响。
do
    local list = Registry.list()
    Assert.eq(#list, #BUILTIN + 2)
    for i, id in ipairs(BUILTIN) do Assert.eq(list[i].id, id) end
    Assert.eq(list[#BUILTIN + 1].id, "ext.demo")
    Assert.eq(list[#BUILTIN + 2].id, "ext.declared", "provides.source = true 是书源")
    Assert.eq(Registry.meta("ext.demo").type, "chapter")
    Assert.is_nil(Registry.meta("ext.old"))
    Assert.is_nil(Registry.meta("demo"))
end

-- 扩展清单含非书源，按加载顺序；非书源不进源列表、不能 resolve / setEnabled。
do
    local exts = Registry.extensions()
    local got = {}
    for _idx, ext in ipairs(exts) do got[#got + 1] = ext.id .. (ext.source and "+" or "-") end
    Assert.eq(table.concat(got, ","), "ext.demo+,ext.widgets-,ext.implicit-,ext.declared+,ext.legacyoff-")
    Assert.eq(exts[2].home_widgets[1].id, "w")
    Assert.eq(exts[2].features.panel, "x.panel", "provides.features 原样记下")
    Assert.is_nil(exts[1].features)
    Assert.eq(Registry.extensionsReady(), true)
    Assert.eq(exts[5].home_widgets[1].id, "l", "旧写法 home 仍然认")
    Assert.len(exts[1].home_widgets, 0)
    Assert.is_nil(Registry.meta("ext.widgets"))
    Assert.is_nil(Registry.external("ext.widgets"))
    Assert.is_nil(Registry.resolve("ext.widgets"))
    Assert.is_false((Registry.setEnabled("ext.widgets", false)))
    Assert.is_nil(Registry.meta("ext.srcnometa"), "声明是书源就得有 meta / new")
    common.active_source = "ext.widgets"
    Assert.eq(Registry.activeId(), "local", "非书源不能当活跃源")
    common.active_source = "moon"
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

-- 第三方 new() 抛错：create 返回错误，不向上抛。
do
    local desc = Registry.external("ext.demo")
    local orig = desc.new
    desc.new = function() error("boom") end
    local src, err = Registry.create("ext.demo")
    Assert.is_nil(src)
    Assert.eq(type(err), "string")
    desc.new = orig
    Assert.is_true(Registry.create("ext.demo").created)
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

-- 仓库里的两个示例扩展符合契约：书源示例声明 source + 首页组件，组件示例不是书源。
do
    local demo = dofile("examples/moonsource-demo.koplugin/moon_source.lua")
    local is_source, widgets = Registry.capabilities(demo)
    Assert.is_true(is_source)
    Assert.eq(widgets[1].id, "hello")
    Assert.eq(type(widgets[1].build), "function")
    local greeting = dofile("examples/moonwidget-demo.koplugin/moon_source.lua")
    is_source, widgets = Registry.capabilities(greeting)
    Assert.is_false(is_source)
    Assert.eq(greeting.id, "ext.greeting")
    Assert.eq(type(widgets[1].settings), "function")
    Assert.is_true(Registry.capabilities({ api = 1 }), "旧描述文件默认是书源")
end

os.execute("rm -rf '" .. root .. "'")
