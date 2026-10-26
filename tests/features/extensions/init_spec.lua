--[[--
features.extensions：收集各插件（不含本插件）可点的主菜单项，坏插件只跳过自己；
显示与否：用户选过按选择，否则第三方显示、自带隐藏；
弹层是锚在底栏格上的主题 List：子菜单逐层进入（首行返回），叶子项按 TouchMenu 规则执行
（回调拿到弹层自己的 closeMenu / updateItems，勾选项执行后刷新不关，其余关），全被隐藏时给一行置灰提示。
@module tests.features.extensions.init_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, need-check-nil

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui.themes"] = function() return { px = function(v) return v end } end
local warned = {}
package.preload["utils.log"] = function()
    return { warn = function(...) warned[#warned + 1] = { ... } end }
end
local cfg, saved = { enabled = true, shown = {}, pinned = {} }, 0
package.preload["utils.settings"] = function()
    return {
        get = function(owner) assert(owner == "features.extensions") return cfg end,
        save = function() saved = saved + 1 end,
    }
end

local modules = {}
package.preload["pluginloader"] = function()
    return { loadPlugins = function() return modules end }
end

local Extensions = require("features.extensions")

local ran = {}
local function inst(items)
    return { addToMainMenu = function(_self, menu) for k, v in pairs(items) do menu[k] = v end end }
end

local toggled = false
local plugin = { path = "/plugins/book.koplugin", ui = {} }
modules = {
    { name = "book", path = "/plugins/book.koplugin" },
    { name = "calibre", path = "/plugins/calibre.koplugin" },
    { name = "zeta", path = "/plugins/zeta.koplugin" },
    { name = "alpha", path = "/plugins/alpha.koplugin" },
    { name = "broken", path = "/plugins/broken.koplugin" },
    { name = "doconly", path = "/plugins/doconly.koplugin" },
    { name = "nomenu", path = "/plugins/nomenu.koplugin" },
}
plugin.ui.book = inst({ book = { text = "月读", callback = function() end } })
plugin.ui.calibre = inst({ calibre = { text = "Calibre", callback = function() ran[#ran + 1] = "calibre" end } })
plugin.ui.zeta = inst({
    zeta = { text = "Zeta", sub_item_table = {
        { text = "开关", checked_func = function() return toggled end, callback = function() toggled = not toggled end },
        { text = "置灰", enabled_func = function() return false end, callback = function() end },
        { text = "仅文案" },
        { text = "深一层", sub_item_table_func = function()
            return { { text = "叶子", callback = function(menu) ran[#ran + 1] = "leaf"; menu:updateItems() end } }
        end },
        { text = "空子菜单", sub_item_table = {} },
    } },
    zeta_sep = { text = "仅文案" },
})
plugin.ui.alpha = inst({ alpha = { text_func = function() return "Alpha" end, keep_menu_open = true,
    callback = function(menu)
        menu:updateItems()
        ran[#ran + 1] = "alpha"
    end } })
plugin.ui.broken = { addToMainMenu = function() error("boom") end }
plugin.ui.nomenu = {}

local function texts(list)
    local out = {}
    for _, item in ipairs(list.items) do out[#out + 1] = item.text end
    return table.concat(out, ",")
end

do -- 收集：排除自己 / 无菜单 / 未实例化；不能点的项不收；第三方在前；坏插件跳过并记日志
    local list = Extensions.entries(plugin)
    Assert.len(list, 3)
    Assert.eq(list[1].id, "alpha:alpha")
    Assert.eq(list[1].text, "Alpha")
    Assert.eq(list[2].id, "zeta:zeta")
    Assert.eq(list[3].id, "calibre:calibre")
    Assert.is_true(list[3].builtin)
    Assert.len(warned, 1)
    Assert.eq(warned[1][2], "broken")
end

do -- 默认：第三方显示、自带隐藏；toggle 记下用户选择并落盘
    local list = Extensions.entries(plugin)
    Assert.is_true(Extensions.isShown(list[1]))
    Assert.eq(Extensions.isShown(list[3]), false)
    Extensions.toggle(list[3])
    Extensions.toggle(list[2])
    Assert.eq(cfg.shown["calibre:calibre"], true)
    Assert.eq(cfg.shown["zeta:zeta"], false)
    Assert.eq(saved, 2)
    cfg.shown["zeta:zeta"] = nil
end

local rect = { x = 400, y = 740, w = 100, h = 60 }

do -- 弹层：居中模式（遮罩、分页）、锚在底栏格、限宽，只列显示的项
    Extensions.show(plugin, rect)
    local list = Themed.last("list")
    Assert.is_true(list.shown)
    Assert.is_true(list.centered)
    Assert.eq(list.anchor, rect)
    Assert.eq(list.inner_width, 240)
    Assert.eq(list.title, "拓展")
    Assert.eq(texts(list), "Alpha,Zeta,Calibre")
    Assert.eq(list.items[2].chevron, true)
    Assert.eq(list.items[1].chevron, false)
end

do -- keep_menu_open 叶子：执行、可调 updateItems，弹层不关
    local list = Themed.last("list")
    list.items[1].callback()
    Assert.eq(ran[1], "alpha")
    Assert.is_nil(list.closed)
end

do -- 子菜单：进入后首行返回；勾选 / 置灰 / 仅文案按原生语义渲染；空子菜单不进入
    local list = Themed.last("list")
    list.items[2].callback()
    Assert.eq(list.title, "Zeta")
    Assert.eq(texts(list), "返回,开关,置灰,仅文案,深一层,空子菜单")
    Assert.eq(list.items[2].icon, "check_box_outline_blank")
    Assert.eq(list.items[3].enabled, false)
    Assert.eq(list.items[4].enabled, false)
    Assert.eq(list.items[5].chevron, true)
    list.items[6].callback()
    Assert.eq(list.title, "Zeta")

    list.items[2].callback() -- 勾选项：执行后刷新，不关
    Assert.is_true(toggled)
    Assert.eq(list.items[2].icon, "check_box")
    Assert.is_nil(list.closed)

    list.items[5].callback() -- 再深一层（sub_item_table_func）
    Assert.eq(list.title, "深一层")
    Assert.eq(texts(list), "返回,叶子")
    list.items[1].callback() -- 返回上一层
    Assert.eq(list.title, "Zeta")
    list.items[1].callback() -- 返回根
    Assert.eq(list.title, "拓展")
    Assert.eq(texts(list), "Alpha,Zeta,Calibre")
end

do -- 普通叶子：执行后关弹层；关了之后插件再调 updateItems 不再重建
    local list = Themed.last("list")
    list.items[3].callback()
    Assert.eq(ran[2], "calibre")
    Assert.is_true(list.closed)
end

do -- 叶子回调里调 updateItems 后，非 keep_menu_open 照样关
    Extensions.show(plugin, rect)
    local list = Themed.last("list")
    list.items[2].callback()
    list.items[5].callback()
    list.items[2].callback()
    Assert.eq(ran[3], "leaf")
    Assert.is_true(list.closed)
end

do -- 全部隐藏：一行置灰提示
    cfg.shown = { ["alpha:alpha"] = false, ["zeta:zeta"] = false }
    Extensions.show(plugin, rect)
    local list = Themed.last("list")
    Assert.len(list.items, 1)
    Assert.eq(list.items[1].enabled, false)
end

do -- 固定到底栏：最多 MAX_PINNED 个；按屏宽剩余空格数取前几个，替换拓展格；没固定仍是一格
    cfg.shown = {}
    local entries = Extensions.entries(plugin)
    local function find(id) for _idx, e in ipairs(entries) do if e.id == id then return e end end end
    Assert.is_nil(Extensions.cells(5))
    Assert.is_true(Extensions.togglePin(find("alpha:alpha"), 1))
    Assert.is_false(Extensions.togglePin(find("zeta:zeta"), 1), "屏宽只容一个时拒绝第二个")
    Assert.is_true(Extensions.togglePin(find("alpha:alpha"), 1))
    Assert.is_true(Extensions.togglePin(find("alpha:alpha")))
    Assert.is_true(Extensions.togglePin(find("zeta:zeta")))
    Assert.is_false(Extensions.togglePin(find("calibre:calibre")), "固定满了拒绝")
    Assert.len(cfg.pinned, 2)
    Assert.is_nil(Extensions.cells(5), "没开固定模式仍是拓展格")
    Assert.is_true(Extensions.isShown(find("alpha:alpha")), "没开固定模式时固定入口仍在菜单里")
    cfg.pin_mode = true
    Assert.is_false(Extensions.isShown(find("alpha:alpha")), "开了固定模式，固定入口不进菜单")
    Extensions.setPinIcon(find("alpha:alpha"), "star")
    Assert.eq(Extensions.pinIcon(find("alpha:alpha")), "star")
    local cells = Extensions.cells(1)
    Assert.len(cells, 2)
    Assert.eq(cells[1].id, "extensions:alpha:alpha")
    Assert.eq(cells[1].icon, "star")
    Assert.len(Extensions.cells(0), 1, "没有空格时只留一个，等于替换原来那一格")
    Assert.is_true(Extensions.togglePin(find("alpha:alpha")))
    Assert.eq(cfg.pinned[1].id, "zeta:zeta")
    cfg.pinned = {}
    Assert.len(Extensions.cells(5), 0, "开了固定模式但没固定入口：不放格子")
    cfg.pin_mode = false
end

do -- 点固定格：叶子直接执行；有子菜单弹层；入口没了退回完整弹层
    Extensions.run(plugin, "calibre:calibre", rect)
    Assert.eq(ran[#ran], "calibre")
    local before = #Themed.all("list")
    Extensions.run(plugin, "zeta:zeta", rect)
    Assert.eq(#Themed.all("list"), before + 1)
    Extensions.run(plugin, "gone:x", rect)
    Assert.eq(#Themed.all("list"), before + 2)
end

do -- 动态回调入口：收集时不执行工厂，弹层与固定格点击时才取当前回调。
    modules[#modules + 1] = { name = "dynamic", path = "/plugins/dynamic.koplugin" }
    local resolved, clicked = 0, 0
    plugin.ui.dynamic = inst({
        dynamic = {
            text = "Dynamic",
            callback_func = function()
                resolved = resolved + 1
                return function(menu)
                    clicked = clicked + 1
                    menu:closeMenu()
                end
            end,
        },
    })
    local found
    for _idx, entry in ipairs(Extensions.entries(plugin)) do
        if entry.id == "dynamic:dynamic" then found = entry end
    end
    Assert.not_nil(found, "callback_func 与 callback 一样是有效入口")
    Assert.eq(resolved, 0, "收集入口不能提前解析动态回调")
    Extensions.show(plugin, rect)
    local list = Themed.last("list")
    local row
    for _idx, item in ipairs(list.items) do
        if item.text == "Dynamic" then row = item end
    end
    Assert.not_nil(row)
    Assert.is_true(row.enabled)
    Assert.eq(resolved, 0)
    row.callback()
    Assert.eq(resolved, 1)
    Assert.eq(clicked, 1)
    Assert.is_true(list.closed)
    Extensions.run(plugin, "dynamic:dynamic", rect)
    Assert.eq(resolved, 2)
    Assert.eq(clicked, 2)
end
