--[[-- reader.page：阅读图标动作与 ReaderUI 接线。 --]]

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
-- registry 一次性加载全部动作模块，font 动作会拉真身 ui.fonts（ui/font + fontlist）
package.preload["ui.fonts.reader"] = function()
    return {
        -- 与真身同契约：非 CRengine 文档（本 spec 的假 ui）不支持换字体
        supports = function(u)
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
package.preload["features.panel.native"] = function()
    return { onCreate = function(ui) native_ui = ui end }
end
package.preload["reader.highlight_menu"] = function()
    return { install = function() end }
end
package.preload["reader.selection"] = function()
    return { install = function() end }
end
local sidebar_installed_on
package.preload["features.sidebar"] = function()
    local Sidebar = {}
    function Sidebar.install(arg)
        sidebar_installed_on = arg
    end
    function Sidebar.onReaderReady(plugin)
        local reader_ui = plugin and plugin.ui
        if not reader_ui then return end
        Sidebar.install(reader_ui)
    end
    return Sidebar
end

local active = true
local sync_source = { id = "moon" }
local current = { identity = { source_id = "moon", stable_id = "b1", source = sync_source } }
package.preload["reader.session"] = function()
    return {
        current = function()
            return active and current or nil
        end,
        toc = function() return nil end,
    }
end

-- 阅读动作顺序来自配置；测试里用干净配置，避免读取模拟器遗留的 quick_panel_reader_actions。
local moon_settings = { book_xray_enabled = true }
package.preload["utils.settings"] = function()
    return {
        get = function() return moon_settings end,
        save = function() end,
    }
end

local registered_modules = {}
local bars_installed_on
-- install 是点号定义（首参就是 ui）：stub 必须按真身的约定校验，
-- 否则 reader.lua 写成 bars:install(ui) 也照样绿——真机上第二本书起底栏劫持全失效。
package.preload["features.bars"] = function()
    local Bars = {}
    function Bars.install(arg)
        bars_installed_on = arg
    end
    function Bars:startClock()
        -- registerViewModule 会把 ui/view 挂到模块上，冒号调用是这里的约定
        assert(self == Bars, "startClock 必须以方法形式调用")
    end
    function Bars.onReaderReady(plugin)
        local reader_ui = plugin and plugin.ui
        if not reader_ui or not reader_ui.view or not reader_ui.view.registerViewModule then return end
        reader_ui.view:registerViewModule("book_bars", Bars)
        Bars.install(reader_ui)
        Bars:startClock()
    end
    return Bars
end
package.preload["features.lockscreen"] = function()
    return { refresh = function() error("翻页不得重绘锁屏") end }
end
package.preload["features.translate"] = function() return {} end
package.preload["features.reflow"] = function() return { available = function() return false end, active = function() return false end } end
package.preload["features.animation"] = function()
    return { isEnabled = function() return false end }
end
package.preload["features.xray.marks"] = function()
    return { install = function() end, enabled = function() return false end }
end
-- 段评关联动作只对有微信读书的本地书可用，本 spec 只看核心动作
package.preload["features.reviews.link"] = function()
    return { available = function() return false end }
end

local bookmarked, toggles = false, 0
local ui = {
    dialog = {},
    document = { file = "/books/page-spec.epub" },
    highlight = { _highlight_buttons = {}, addToHighlightDialog = function() end },
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
            registered_modules[name] = module
        end,
        registerTouchZones = function() end,
        footer = {},
    },
    registerTouchZones = function() end,
}
local plugin = { ui = ui }

local Reader = require("reader.page")
-- 真机由 features 加载器把 onReaderReady 分发登记到 reader.ready
require("utils.extension").add("reader.ready", function(p) require("features").emit("onReaderReady", p) end)
local PanelReader = require("features.panel.reader")
local actions = PanelReader.actions(ui)
local action_ids = {}
for _, a in ipairs(actions) do action_ids[#action_ids + 1] = a.id end
Assert.eq(table.concat(action_ids, ","), "toc,highlights,rare_ruby,xray,xray_marks,xray_refresh")
Assert.eq(actions[1].icon, "menu_book")

Assert.is_false(PanelReader.executeAction("missing", ui))

local margin = { name = "t_page_margin", hide_on_apply = true }
local other = { name = "font_size", hide_on_apply = true }
package.preload["ui/data/creoptions"] = function() return { { options = { margin, other } } } end
Reader.onCreate(plugin)
Assert.is_nil(margin.hide_on_apply, "边距调整不收起面板、不弹信息框")
Assert.is_true(other.hide_on_apply)
moon_settings.margin_popup = true
native_ui = nil
ui._book_reader_attached = nil
Reader.onCreate(plugin)
Assert.is_true(margin.hide_on_apply, "开关打开时恢复原生信息框")
moon_settings.margin_popup = nil
ui._book_reader_attached = nil
Reader.onCreate(plugin)
Assert.is_nil(margin.hide_on_apply)
Assert.eq(native_ui, ui)
Assert.not_nil(registered_modules.book_bars)
Assert.not_nil(registered_modules.book_page_marks)
Assert.eq(bars_installed_on, ui, "install 的首参必须是 ReaderUI，不能是模块自己")
Assert.eq(sidebar_installed_on, ui, "阅读页必须安装侧栏手势")
Assert.is_nil(ui._zones, "不应注册覆盖原生菜单的触摸区")

native_ui = nil
Reader.onCreate(plugin)
Assert.is_nil(native_ui, "同一 ReaderUI 不应重复安装")

