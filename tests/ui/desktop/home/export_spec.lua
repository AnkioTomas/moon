--[[--
Home export works without Desktop, waits for child data and preserves target dimensions.
@module tests.ui.desktop.home.export_spec
--]]
local Assert = require("support.assert")
local function widget()
    return { new = function(_, opts)
        opts.getSize = function(self)
            return self.dimen or (self[1] and self[1]:getSize()) or { w = 0, h = 0 }
        end
        opts.paintTo = function(self, bb, x, y)
            for _, child in ipairs(self) do child:paintTo(bb, x, y) end
        end
        opts.free = function(self)
            for _, child in ipairs(self) do if child.free then child:free() end end
        end
        return opts
    end }
end
for _, name in ipairs({
    "container/widgetcontainer", "container/framecontainer", "container/inputcontainer",
    "verticalgroup", "verticalspan",
}) do package.preload["ui/widget/" .. name] = widget end
package.preload["ui/geometry"] = function() return { new = function(_, opts) return opts end } end
package.preload["ui/gesturerange"] = widget
package.preload["device"] = function() return { screen = {} } end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 255 } end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() error("export must not dirty the screen") end,
        scheduleIn = function() error("export must not start timers") end }
end
package.preload["ui.components.bookui"] = function()
    return { sz = function(n) return n end, topBarH = function() return 10 end }
end
package.preload["ui.components.pagestrip"] = function()
    return { bandH = function() return 20 end, widget = function() return widget():new{} end }
end
package.preload["ui.desktop.home.edit_overlay"] = function() return {} end
package.preload["ui.desktop.home.widgets"] = function() return {} end

local pending, cancellations, resumes, painted = {}, 0, 0, {}
local Component = setmetatable({ id = "probe" }, require("ui.desktop.home.views.base"))
Component.__index = Component
function Component:loadData(done)
    pending[#pending + 1] = done
    return { cancel = function() cancellations = cancellations + 1 end }
end
function Component:createWidget()
    local data = self.data
    return { dimen = { w = self.opts.width, h = self.opts.height },
        getSize = function(self) return self.dimen end,
        paintTo = function() painted[#painted + 1] = data end,
        free = function() end }
end
function Component:onResume() resumes = resumes + 1 end
package.preload["ui.desktop.home.registry"] = function()
    return { enabledLayout = function() return { "probe" } end,
        find = function() return Component end,
        needsSplit = function() error("export must not migrate settings") end }
end
package.preload["ui.desktop.home.layout"] = function()
    return { new = function()
        return { build = function(_, ctx, components, page, opts)
            Assert.eq(ctx.width, 320)
            Assert.eq(ctx.height, 480)
            local root = components.probe:build(ctx, { width = ctx.width, height = opts.body_height })
            return root, 1, 1, { probe = true }
        end }
    end }
end
local image_done
package.preload["ui.components.image"] = function()
    return { await = function(_, cb)
        image_done = cb
        return { cancel = function() end }
    end }
end
local writes = 0
package.preload["ui.render"] = function()
    return { write = function(_, w, h, paint)
        Assert.eq(w, 320)
        Assert.eq(h, 480)
        writes = writes + 1
        paint({})
        return true
    end,
    paintWidget = function(bb, block, w, h)
        local size = block.widget:getSize()
        Assert.eq(size.w, w)
        Assert.eq(size.h, h)
        block.widget:paintTo(bb, 0, 0)
    end }
end
local Home = require("ui.desktop.home")
local callbacks = 0
Home:renderToImage({ path = "unused.png", width = 320, height = 480 }, function(ok)
    Assert.is_true(ok)
    callbacks = callbacks + 1
end)
Assert.eq(#pending, 1)
Assert.eq(writes, 0)
pending[1]("loaded")
Assert.eq(writes, 0, "data completion must still wait for pictures")
image_done()
Assert.eq(writes, 1)
Assert.eq(painted[1], "loaded")
Assert.eq(callbacks, 1)
Assert.eq(resumes, 0)
local cancelled = Home:renderToImage({ path = "unused.png", width = 320, height = 480 }, function()
    error("cancelled export must not call back")
end)
cancelled:cancel()
Assert.eq(cancellations, 1)
pending[2]("too late")
Assert.eq(writes, 1)
