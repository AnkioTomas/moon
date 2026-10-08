--[[--
ui.themes：三套令牌键集合与取值类型一致、灰度合法；当前主题读 display.ui_theme，未设或写错回落 paper。

@module tests.ui.themes.init_spec
--]]

local Assert = require("support.assert")

local display = {}
package.preload["utils.settings"] = function()
    return {
        get = function(section) assert(section == "ui"); return display end,
        save = function() end,
    }
end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, n) return n * 2 end } }
end
package.preload["ui/font"] = function()
    return { getFace = function(_, name, size) return { name = name, size = size } end }
end

local Theme = require("ui.themes")

--- 递归收集「路径 → 类型」，用来比较两套令牌的形状。
---@param t table
---@param prefix string
---@param out table
---@return table
local function shape(t, prefix, out)
    for k, v in pairs(t) do
        local path = prefix .. "." .. k
        out[path] = type(v)
        if type(v) == "table" then shape(v, path, out) end
    end
    return out
end

local base = shape(Theme.get("paper"), "", {})
for _, id in ipairs(Theme.ids) do
    local tokens = Theme.get(id)
    Assert.eq(tokens.id, id)
    local s = shape(tokens, "", {})
    for path, kind in pairs(base) do
        Assert.eq(s[path], kind, id .. " 令牌形状不一致: " .. path)
    end
    for path in pairs(s) do
        Assert.not_nil(base[path], id .. " 多出令牌: " .. path)
    end
    for _, group in pairs(tokens) do
        if type(group) == "table" then
            for key, v in pairs(group) do
                if type(v) == "number" and (key == "bg" or key == "ink" or key:match("color$")) then
                    Assert.is_true(v >= 0 and v <= 255 and v == math.floor(v), id .. " 灰度越界: " .. key)
                end
            end
        end
    end
    for name, v in pairs(tokens.color) do
        Assert.is_true(v >= 0 and v <= 255 and v == math.floor(v), id .. " 灰度越界: color." .. name)
    end
end

-- 当前主题：未设 / 写错回落 paper，合法值按设置取。
display.ui_theme = nil
Assert.eq(Theme.current().id, "paper")
display.ui_theme = "neon"
Assert.eq(Theme.current().id, "paper")
display.ui_theme = "bold"
Assert.eq(Theme.current().id, "bold")
display.ui_theme = "soft"
Assert.eq(Theme.current().id, "soft")
Assert.eq(Theme.id(), "soft")
Assert.eq(Theme.set("paper"), "paper")
Assert.eq(display.ui_theme, "paper")
Assert.eq(Theme.set("neon"), "paper", "未知主题不落盘")
Assert.eq(display.ui_theme, "paper")

Assert.errors(function() Theme.get("neon") end, "unknown ui theme")

-- 缩放：读 display.ui_scale（缺省 130，夹到 100–180）；px = DPI × 缩放，0 保持 0、其余至少 1。
display.ui_scale = nil
Assert.eq(Theme.scale(), 130)
display.ui_scale = 50
Assert.eq(Theme.scale(), 100)
display.ui_scale = 300
Assert.eq(Theme.scale(), 180)
display.ui_scale = 150
Assert.eq(Theme.px(0), 0)
Assert.eq(Theme.px(3), 9, "3 × DPI 2 × 150%")
Assert.eq(Theme.px(0.1), 1, "非零至少 1px")
-- 字号只乘缩放（DPI 由 Font:getFace 乘），下限 10。
Assert.eq(Theme.fontSize(14), 21)
Assert.eq(Theme.fontSize(4), 10)
Assert.eq(Theme.face("cfont", 14).size, 21)
Assert.matches(Theme.root(), "/book%.koplugin/$")
Assert.eq(Theme.setScale(125), 130, "按 10 取整")
Assert.eq(display.ui_scale, 130)
Assert.eq(Theme.setScale(50), 100)

return true
