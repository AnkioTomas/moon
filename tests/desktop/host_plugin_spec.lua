--[[--
Desktop.hostPlugin：PluginLoader 用目录名挂实例。目录叫 book.koplugin 时是 ui.book；
叫错（fontmap.koplugin）时 ui.book 是 nil，写死 .book 就会 Desktop.open(nil)。

@module tests.desktop.host_plugin_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.sections.store = {}
Kit.sections.extensions = {}
Kit.sections.subscribe = {}
Kit.sections.clock = { ntp_auto = false }
Kit.sections.desktop = { tab_icons = {} }

for _, name in ipairs({ "home", "library", "store", "insight" }) do
    package.preload["desktop.pages." .. name] = function()
        local P = { __index = {} }
        function P:new(o) return setmetatable(o or {}, self) end
        function P:updateView() return require("ui/widget/widget"):new{} end
        function P:id() return name end
        function P:activate() end
        function P:deactivate() end
        function P:destroy() end
        function P.providers() return {} end
        return P
    end
end
package.preload["desktop.pages.setting"] = package.preload["desktop.pages.home"]
package.preload["desktop.sync"] = function()
    return { open = function() end, onClose = function() end }
end
package.preload["desktop.topbar"] = function()
    return {
        height = function() return 30 end,
        build = function() return require("ui/widget/widget"):new{ dimen = { w = 100, h = 30 } } end,
    }
end
package.preload["utils.log"] = function()
    return { dbg = function() end, info = function() end, error = function() end, flush = function() end }
end

local Desktop = require("desktop")

-- 名字对了：ui.book 就是宿主
local book = { name = "book", path = "/plugins/book.koplugin" }
local fm = { book = book }
Assert.eq(Desktop.hostPlugin(fm), book)
Assert.eq(Desktop.hostPlugin(fm, book), book)

-- 名字错了：ui.book 是 nil，但 hint.name 对得上时仍能从 FM 取到
local misnamed = { name = "fontmap", path = "/plugins/fontmap.koplugin" }
local fm_bad = { fontmap = misnamed }
Assert.is_nil(fm_bad.book, "写死 fm.book 在这里就是 nil——截图像里的崩")
Assert.eq(Desktop.hostPlugin(fm_bad, misnamed), misnamed, "按 hint.name 找到宿主")

-- 正确 path 后缀也能认（即使 name 不是 book）
local weird = { name = "x", path = "/mnt/us/koreader/plugins/book.koplugin" }
Assert.eq(Desktop.hostPlugin({ x = weird }), weird)

return true
