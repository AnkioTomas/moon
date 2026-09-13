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
    "utils.log",
    "utils.perf",
    "ui.desktop.library",
    "ui.desktop.store",
    "ui.desktop.insight",
    "ui.desktop.settings",
    "ui.desktop.detail",
    "ui.panel.native",
    "ui.components.image",
    "ui.views.topbar",
    "ui.desktop.settings.source",
    "ui.views.bottombar",
    "ui.components.bookui",
    "book.store",
}) do
    package.preload[name] = emptyModule
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, fn) fn() end, setDirty = function() end }
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
    return { new = function() return {} end }
end

package.loaded["ui.desktop"] = nil
local Desktop = require("ui.desktop")

local view_updates = 0
local pauses, resumes = 0, 0
local desktop
desktop = {
    lifecycle = { state = "Resume" },
    tab = "home",
    insight = {
        onResume = function(self, changed)
            Assert.is_true(changed)
            self.resumed = true
        end,
        ui_page = 3,
        state = { stale = true },
        loaded = true,
    },
    settings = {
        showSub = function(self, sub, parent)
            self.sub = sub
            self.parent = parent
            self.page = 1
            desktop:updateView()
        end,
    },
    home = {
        onPause = function() pauses = pauses + 1 end,
        onResume = function() resumes = resumes + 1 end,
    },
    library = {},
    store = {},
    updateView = function() view_updates = view_updates + 1 end,
}

Desktop.switchTab(desktop, "insight")
Assert.eq(desktop.tab, "insight")
Assert.is_true(desktop.insight.resumed)
Assert.eq(desktop.insight.ui_page, 3)
Assert.not_nil(desktop.insight.state)
Assert.is_true(desktop.insight.loaded)
Assert.eq(view_updates, 1)

desktop.settings:showSub("home", "desktop")
Assert.eq(desktop.settings.sub, "home")
Assert.eq(desktop.settings.parent, "desktop")
Assert.eq(desktop.settings.page, 1)
Assert.eq(view_updates, 2)

desktop.settings:showSub()
Assert.is_nil(desktop.settings.sub)
Assert.is_nil(desktop.settings.parent)
Assert.eq(view_updates, 3)
Assert.eq(pauses, 1)
Desktop.switchTab(desktop, "home")
Assert.eq(resumes, 1)
Assert.eq(pauses, 1)
Assert.eq(view_updates, 4)

local swipes = {}
desktop.library.onEvent = function(_, event, payload)
    swipes[#swipes + 1] = { event = event, direction = payload and payload.direction }
end
Desktop.onEvent(desktop, "swipe", { direction = "west" })
Assert.eq(swipes[1].event, "swipe")
Assert.eq(swipes[1].direction, "west")
