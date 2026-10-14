--[[-- features.panel.widget.body 现场编辑离线用例。 --]]

local Assert = require("support.assert")

local function widget()
    local W = {}
    function W:extend(proto)
        local C = {}
        setmetatable(C, { __index = proto })
        function C:new(o)
            o = o or {}
            setmetatable(o, { __index = C })
            if o.init then o:init() end
            return o
        end
        return C
    end
    W.new = function(_, opts)
        local o = opts or {}
        setmetatable(o, { __index = W })
        if o.init then o:init() end
        return o
    end
    return W
end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/verticalgroup"] = function()
    local W = widget()
    local original_new = W.new
    W.new = function(_, opts)
        local o = original_new(_, opts)
        o.getSize = function() return { w = 200, h = 100 } end
        return o
    end
    return W
end
package.preload["ui/widget/verticalspan"] = widget
package.preload["ui.themes"] = function()
    return { px = function(n) return n end, current = function() return {} end }
end
package.preload["ui.themes.widgets.icon"] = function()
    return {
        label = function(opts) return opts end,
        widget = function(opts) return opts end,
    }
end
package.preload["features.panel.widget.button"] = function()
    local Button = {}
    Button.__index = Button
    function Button:new(opts)
        return setmetatable(opts, self)
    end
    return Button
end
package.preload["features.panel.widget.slider"] = function()
    return { new = function(_, opts) return opts end }
end

local wraps, dones, adds = 0, 0, 0
local last_handlers
package.preload["features.panel.edit_overlay"] = function()
    return {
        wrap = function(button, meta, handlers)
            wraps = wraps + 1
            last_handlers = handlers
            return { wrapped = true, id = meta.id, index = meta.index, button = button }
        end,
        showAddDialog = function() end,
    }
end
package.preload["ui.themes.widgets.button"] = function()
    return {
        new = function(_, opts)
            if opts.text == "完成" then dones = dones + 1 end
            if opts.text == "添加动作" then adds = adds + 1 end
            return opts
        end,
    }
end

local Body = require("features.panel.widget.body")

local entered = false
local body = Body:new{
    width = 300,
    actions = {
        { id = "night", title = "夜间", icon = "dark_mode" },
        { id = "wifi", title = "Wi-Fi", icon = "wifi" },
    },
    sliders = { { kind = "brightness", title = "亮度", value = 40 } },
    on_action = function() end,
    on_enter_edit = function() entered = true end,
    addable = function() return { { id = "rotate", title = "旋转" } } end,
}
Assert.eq(wraps, 0)
Assert.eq(dones, 0)
Assert.not_nil(body.ges_events)
Assert.is_true(body:onHoldPanelEdit())
Assert.is_true(entered)

wraps, dones, adds = 0, 0, 0
local editing = Body:new{
    width = 300,
    editing = true,
    actions = {
        { id = "night", title = "夜间", icon = "dark_mode" },
        { id = "wifi", title = "Wi-Fi", icon = "wifi" },
    },
    sliders = { { kind = "brightness", title = "亮度", value = 40 } },
    on_exit_edit = function() end,
    on_move = function() end,
    on_disable = function() end,
    addable = function() return { { id = "rotate", title = "旋转" } } end,
}
Assert.eq(wraps, 2)
Assert.eq(dones, 1)
Assert.eq(adds, 1)
-- 编辑态不挂长按，但必须是空表而不是 nil：InputContainer:onGesture 会 pairs(self.ges_events)，
-- nil 被任意手势碰到就是 pairs(nil) 报错（真机上报「月读出错了」）。
Assert.not_nil(editing.ges_events)
Assert.is_nil(editing.ges_events.HoldPanelEdit)
Assert.eq(#editing.ges_events, 0, "编辑态手势表为空：既不挂长按也不会让 pairs 崩")

-- 前移 / 后移按可见顺序找邻居：完整启用列表里可能夹着当前不可用的项，不能交给 ±1。
local swaps = {}
Body:new{
    width = 300,
    editing = true,
    actions = {
        { id = "night", title = "夜间", icon = "dark_mode" },
        { id = "rotate", title = "旋转", icon = "rotate" },
        { id = "suspend", title = "休眠", icon = "mode_standby" },
    },
    on_exit_edit = function() end,
    on_move = function(id, other) swaps[#swaps + 1] = id .. ">" .. other end,
    on_disable = function() end,
    addable = function() return {} end,
}
Assert.eq(adds, 1, "没有可添加项时不出「添加动作」")
last_handlers.on_move("rotate", -1)
last_handlers.on_move("rotate", 1)
Assert.eq(swaps[1], "rotate>night")
Assert.eq(swaps[2], "rotate>suspend")

return true
