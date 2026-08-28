--[[-- ui.reader：阅读图标动作与 ReaderUI 接线。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            getDPI = function() return 160 end,
            scaleBySize = function(_, n) return n end,
        },
        hasWifiToggle = function() return true end,
    }
end
-- registry 一次性加载全部动作模块，font 动作会拉真身 utils.font（ui/font + fontlist）
package.preload["utils.font"] = function()
    return {
        -- 与真身同契约：非 CRengine 文档（本 spec 的假 ui）不支持换字体
        supportsReader = function(u)
            return u and u.font ~= nil and type(u.document) == "table"
                and type(u.document.setFontFace) == "function" or false
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return { isWifiOn = function() return false end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end

local native_ui
package.preload["ui.panel.native"] = function()
    return { install = function(ui) native_ui = ui end }
end

local active = true
local sync_source = { id = "moon" }
local current = { identity = { source_id = "moon", stable_id = "b1", source = sync_source } }
package.preload["ui.reader.session"] = function()
    return {
        current = function()
            return active and current or nil
        end,
        toc = function() return nil end,
    }
end
package.preload["ui.reader.dictionary"] = function()
    return { open = function() end }
end

-- 阅读动作顺序来自配置；测试里用干净配置，避免读取模拟器遗留的 quick_panel_reader_actions。
local moon_settings = {}
package.preload["utils.settings"] = function()
    return {
        get = function() return moon_settings end,
        save = function() end,
    }
end

local registered_module
local bars_installed_on
-- install 是点号定义（首参就是 ui）：stub 必须按真身的约定校验，
-- 否则 reader.lua 写成 bars:install(ui) 也照样绿——真机上第二本书起底栏劫持全失效。
package.preload["ui.reader.bars"] = function()
    local Bars = {}
    function Bars.install(arg)
        bars_installed_on = arg
    end
    function Bars:startClock()
        -- registerViewModule 会把 ui/view 挂到模块上，冒号调用是这里的约定
        assert(self == Bars, "startClock 必须以方法形式调用")
    end
    return Bars
end
package.preload["lockscreen.init"] = function()
    return { refreshInBackground = function() end }
end
package.preload["xray.marks"] = function()
    return { install = function() end }
end

local bookmarked, toggles = false, 0
local ui = {
    dialog = {},
    toc = { onShowToc = function() end },
    bookmark = {
        isPageBookmarked = function() return bookmarked end,
        onToggleBookmark = function()
            bookmarked = not bookmarked
            toggles = toggles + 1
        end,
        onShowBookmark = function() end,
    },
    dictionary = {
        onShowDictionaryLookup = function() end,
        showDictionariesMenu = function() end,
    },
    view = {
        registerViewModule = function(_, name, module)
            registered_module = { name = name, module = module }
        end,
        registerTouchZones = function() end,
        footer = {},
    },
}
local plugin = { ui = ui }

local Reader = require("ui.reader")
local actions = Reader.actions(ui)
Assert.len(actions, 4)
Assert.eq(actions[1].id, "toc")
Assert.eq(actions[1].icon, "menu_book")
Assert.eq(actions[2].id, "highlights")
Assert.eq(actions[3].id, "xray")
Assert.eq(actions[4].id, "dictionary")

Assert.is_false(Reader.executeAction("missing", ui))

Reader.attach(plugin)
Assert.eq(native_ui, ui)
Assert.eq(registered_module.name, "book_bars")
Assert.eq(bars_installed_on, ui, "install 的首参必须是 ReaderUI，不能是模块自己")
Assert.is_nil(ui._zones, "不应注册覆盖原生菜单的触摸区")

native_ui = nil
Reader.attach(plugin)
Assert.is_nil(native_ui, "同一 ReaderUI 不应重复安装")
