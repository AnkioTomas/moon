--[[--
插件启动默认启用原生脚注弹窗，且只初始化一次。

@module tests.main_spec
--]]

local Assert = require("support.assert")

local saved = {}
local reader_settings = {
    isTrue = function(_, key) return saved[key] == true end,
    saveSetting = function(_, key, value) saved[key] = value end,
}
_G.G_reader_settings = reader_settings

local WidgetContainer = {}
function WidgetContainer:extend(def)
    def.__index = def
    return setmetatable(def, { __index = self })
end

local calls = {}
local function stub(name, value)
    package.preload[name] = function() return value end
end

stub("ui/widget/container/widgetcontainer", WidgetContainer)
stub("ui/uimanager", { nextTick = function(_, fn) fn() end })
stub("ui/widget/infomessage", {})
stub("logger", { err = function() end, info = function() end })
stub("l10n", {})
stub("gettext", setmetatable({}, { __call = function(_, text) return text end }))
stub("source.registry", {})
stub("ui.desktop", {})
stub("book.open", {})
stub("host", { attach = function() calls.host = (calls.host or 0) + 1 end })
stub("http.request", { ensureTurbo = function() end })
stub("translate.init", { install = function() calls.translate = (calls.translate or 0) + 1 end })
stub("baike.init", { install = function() calls.baike = (calls.baike or 0) + 1 end })
stub("dictionary.init", { install = function() calls.dictionary = (calls.dictionary or 0) + 1 end })
stub("ui.panel.native", { install = function() calls.panel = (calls.panel or 0) + 1 end })
stub("lockscreen.init", {
    bootstrap = function() calls.lockscreen = (calls.lockscreen or 0) + 1 end,
    refresh = function(_, force) calls.lock_refresh = force end,
})
stub("ui.reader.session", { onSuspend = function() calls.session_suspend = true end })
stub("remote.init", {
    bootstrap = function() calls.remote = (calls.remote or 0) + 1 end,
    onSuspend = function() calls.remote_suspend = true end,
})
stub("ui.screenshot_share", { install = function() calls.screenshot_share = (calls.screenshot_share or 0) + 1 end })
stub("pinyin.init", { bootstrap = function() calls.pinyin = (calls.pinyin or 0) + 1 end })
stub("patch.manager", { init = function() calls.patch = (calls.patch or 0) + 1 end })
stub("patch.page_turn_animation", { checkStartup = function() calls.animation = (calls.animation or 0) + 1 end })

local Main = require("main")
local plugin = setmetatable({ path = "book.koplugin" }, Main)
plugin:init()
Assert.is_true(saved.footnote_link_in_popup)
Assert.is_true(saved.book_footnote_popup_initialized)
Assert.eq(calls.screenshot_share, 1)

saved.footnote_link_in_popup = false
plugin:init()
Assert.is_false(saved.footnote_link_in_popup, "用户关闭后不得在后续启动时重新打开")

plugin:onSuspend()
Assert.is_true(calls.session_suspend)
Assert.is_true(calls.lock_refresh)
Assert.is_true(calls.remote_suspend)
