--[[--
切 Tab 时 View 根必须 keep_old：否则 free → Destroy，再 Resume 炸 cannot resume destroyed lifecycle。
@module tests.ui.desktop.tab_keep_old_spec
--]]

local Assert = require("support.assert")

package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["ui/geometry"] = function()
    local Geom = {}
    Geom.__index = Geom
    function Geom:new(rect) return setmetatable(rect, self) end
    return Geom
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return {
        new = function(_, opts)
            opts.getSize = function(self) return self[1]:getSize() end
            opts.free = function(self)
                if self[1] and self[1].free then self[1]:free() end
            end
            return opts
        end,
    }
end

local Lifecycle = require("ui.lifecycle")
local View = require("ui.view")
local Page = setmetatable({}, View)
Page.__index = Page
function Page:createWidget()
    return {
        getSize = function() return { w = 10, h = 10 } end,
        free = function() end,
    }
end

local desktop = {}
desktop.lifecycle = Lifecycle.attach(desktop)
desktop.lifecycle.state = "Resume"
local shell = View.attach(desktop)

local settings = Page:new{ name = "settings" }
settings:onCreate()
local settings_root = settings:build()
Assert.eq(settings_root._view_owner, settings)

local home_leaf = { getSize = function() return { w = 10, h = 10 } end, free = function() end }
local container = { settings_root }
shell:registerRegion("content", container, 1, function()
    return { x = 0, y = 0, w = 10, h = 10 }
end)

-- Desktop:updateView 传 keep_old=_view_owner：设置页根保留，可再 Resume。
shell:replaceRegion("content", home_leaf, settings_root._view_owner)
Assert.eq(settings.lifecycle.state, "Create", "keep_old 不得 Destroy 设置页")
settings:onPause()
settings:onResume()
Assert.eq(settings.lifecycle.state, "Resume")

-- 反证：不传 keep_old（旧 Home:install 行为）会 Destroy，再 Resume 必炸。
local doomed = Page:new{ name = "doomed" }
doomed:onCreate()
local doomed_root = doomed:build()
container[1] = doomed_root
shell:replaceRegion("content", home_leaf)
Assert.eq(doomed.lifecycle.state, "Destroy")
Assert.errors(function() doomed:onResume() end, "cannot resume destroyed lifecycle")

return true
