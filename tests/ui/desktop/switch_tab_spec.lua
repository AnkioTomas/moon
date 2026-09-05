--[[-- 桌面 Tab 与设置子页导航状态。 --]]

local Assert = require("support.assert")

local function emptyModule() return {} end
for _, name in ipairs({
    "ui/bidi",
    "ffi/blitbuffer",
    "ui/widget/container/framecontainer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/overlapgroup",
    "ui/uimanager",
    "utils.log",
    "utils.perf",
    "ui.desktop.library",
    "ui.desktop.store",
    "ui.desktop.insight",
    "ui.desktop.settings",
    "ui.desktop.detail",
    "ui.panel.native",
    "ui.components.image",
    "ui.components.topbar",
    "ui.desktop.settings.source",
    "ui.components.bottombar",
    "ui.components.bookui",
    "book.store",
}) do
    package.preload[name] = emptyModule
end
package.preload["device"] = function() return { screen = {} } end
package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["ui/widget/container/inputcontainer"] = function()
    return {
        extend = function(_, value) return value end,
    }
end
package.preload["ui.desktop.home"] = function()
    return { refreshOnEnter = function() end }
end

package.loaded["ui.desktop"] = nil
local Desktop = require("ui.desktop")

local rebuilds = 0
local desktop = {
    tab = "home",
    _insight_ui_page = 3,
    _insight_state = { stale = true },
    _insight_loaded = true,
    rebuild = function() rebuilds = rebuilds + 1 end,
}

Desktop.switchTab(desktop, "stats")
Assert.eq(desktop.tab, "stats")
Assert.eq(desktop._insight_ui_page, 1)
Assert.is_nil(desktop._insight_state)
Assert.is_false(desktop._insight_loaded)
Assert.eq(rebuilds, 1)

Desktop.showSettingsSub(desktop, "home", "desktop")
Assert.eq(desktop._settings_sub, "home")
Assert.eq(desktop._settings_parent, "desktop")
Assert.eq(desktop._settings_page, 1)
Assert.eq(rebuilds, 2)

Desktop.showSettingsSub(desktop, nil)
Assert.is_nil(desktop._settings_sub)
Assert.is_nil(desktop._settings_parent)
Assert.eq(rebuilds, 3)

