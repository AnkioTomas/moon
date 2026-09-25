--[[-- 设置叠层：预览框不进分页，分组只铺设置项。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end }, hasKeys = function() return false end }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1 } end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
for _, name in ipairs({
    "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/textwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/linewidget",
    "ui/widget/overlapgroup",
    "ui/widget/container/rightcontainer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/inputcontainer",
}) do
    package.preload[name] = function()
        return {
            new = function(_, opts)
                opts = opts or {}
                opts.getSize = function() return { w = opts.w or 10, h = opts.h or 10 } end
                return opts
            end,
            extend = function(_, value) return value end,
        }
    end
end
package.preload["ui.components.bookinfo"] = function()
    return { tappable = function() return {} end }
end
package.preload["ui.components.icon"] = function()
    return { label = function() return { getSize = function() return { w = 40, h = 20 } end } end }
end
package.preload["ui.lifecycle"] = function()
    return { attach = function() return { state = "Resume", uiReady = function() return false end } end }
end
package.preload["ui.components.pager"] = function()
    return {
        bandH = function() return 50 end,
        pack = function(items) return { items } end,
        clamp = function() return 1 end,
        frame = function(_, _, opts) return opts end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(value) return value end,
        sectionGap = function() return 12 end,
        pagePad = function() return 16 end,
        face = function() return {} end,
        muted = function() return 0 end,
        dim = function() return 0 end,
        line = function() return 1 end,
        rule = function() return 0 end,
    }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end, nextTick = function(_, fn) fn() end }
end

local Overlay = require("ui.desktop.settings.overlay")
local packed = {}
Overlay.appendSection(packed, 600, "行为", {
    function() return { title = "脚注弹窗" } end,
    function() return { title = "翻页动画" } end,
})
Assert.is_true(#packed >= 3)
Assert.eq(packed[#packed].title, "翻页动画")

local box = Overlay.previewBox(600, { getSize = function() return { w = 10, h = 10 } end }, 40)
Assert.eq(box.dimen.w, 600)
Assert.eq(box.dimen.h, 40)

local empty = Overlay.previewPlaceholder(600, 40, "关")
Assert.eq(empty.dimen.w, 600)
Assert.eq(empty.dimen.h, 40)

local closed = false
local desktop = { lifecycle = { state = "Resume" } }
desktop.settings_overlay = {
    onClose = function()
        closed = true
        desktop.settings_overlay = nil
    end,
}
Overlay.close(desktop)
Assert.is_true(closed)
Assert.is_nil(desktop.settings_overlay)

return true
