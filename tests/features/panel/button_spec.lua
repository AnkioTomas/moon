--[[-- features.panel.widget.button：形状跟主题 tile.shape 走（bare / circle / block），交互不变。 --]]
---@diagnostic disable: missing-fields, undefined-field

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
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255, Color8 = function(c) return c end }
end
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/verticalgroup"] = widget
package.preload["ui/widget/verticalspan"] = widget
package.preload["ui.themes.widgets.icon"] = function()
    return {
        label = function(opts) return opts end,
        widget = function(opts) return opts end,
    }
end
package.preload["ui.themes.widgets.text"] = function()
    return { line = function(role, text, opts) return { role = role, text = text, opts = opts } end }
end
package.preload["ui.themes.widgets.box"] = function()
    return { new = function(_, opts) return opts end }
end

local shape = "bare"
package.preload["ui.themes"] = function()
    return {
        px = function(n) return n end,
        current = function()
            return {
                tile = { shape = shape },
                button = {
                    primary = { bg = 0, ink = 255, border_color = 0 },
                    normal = { bg = 255, ink = 0, border_color = 0 },
                },
                card = { radius = 0, shadow = 3, shadow_color = 0 },
                control = { border = 2, radius = 2, icon = 22 },
                color = { ink = 0, disabled = 170 },
                space = { xs = 4, sm = 8 },
                font = { caption = 11 },
            }
        end,
    }
end

local ActionButton = require("features.panel.widget.button")

---@param opts table|nil
local function button(opts)
    local o = { width = 80, height = 76, id = "night", title = "夜间", icon = "dark_mode", on_action = function() end }
    for k, v in pairs(opts or {}) do o[k] = v end
    return ActionButton:new(o)
end

--- bare / circle：CenterContainer → VerticalGroup{ 底座 Box, 间距, 文字 }
local function parts(b)
    local group = b[1][1]
    return group[1], group[3]
end

-- bare（paper）：关着无框，图标用正文色；开着垫 primary 底、反色图标，圆角取 control.radius。
shape = "bare"
local base, label = parts(button())
Assert.is_nil(base.style.bg, "关着不画底")
Assert.is_nil(base.style.border, "关着不画框")
Assert.eq(base[1].color, 0)
Assert.eq(base[1].size, 22, "图标字号必填，漏传会在 Theme.fontSize 里崩")
Assert.eq(label.text, "夜间")
base = parts(button{ active = true })
Assert.eq(base.style.bg, 0)
Assert.eq(base.style.radius, 2)
Assert.eq(base[1].color, 255)
Assert.eq(base.width, 44)

-- circle（soft）：总有圆底，开关只换变体；文字在圆外。
shape = "circle"
base = parts(button())
Assert.eq(base.style.bg, 255)
Assert.eq(base.style.radius, 999)
Assert.eq(base.width, 52)
base = parts(button{ active = true })
Assert.eq(base.style.bg, 0)
Assert.eq(base[1].color, 255)

-- block（bold）：卡片的圆角与阴影；阴影从宽高里扣掉，网格不被撑宽。
shape = "block"
local tile = button{ active = true }[1]
Assert.eq(tile.style.radius, 0)
Assert.eq(tile.style.shadow, 3)
Assert.eq(tile.width, 77)
Assert.eq(tile.height, 73)
Assert.eq(tile[1].text, "夜间", "文字在块内")
Assert.eq(tile[1].color, 255)

-- 点按执行。长按不进编辑；只有声明了 on_hold 的按钮才接 hold。
local tapped
Assert.is_true(button{ on_action = function(id) tapped = id end }:onTap())
Assert.eq(tapped, "night")
Assert.is_nil(button().ges_events.Hold)

local held
local holdable = button{ on_hold = function(id) held = id end }
Assert.is_true(holdable.ges_events.Hold ~= nil)
Assert.is_true(holdable:onHold())
Assert.eq(held, "night")
