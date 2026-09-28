--[[--
ui.themes：三套令牌键集合与取值类型一致、灰度合法；当前主题读 display.ui_theme，未设或写错回落 paper。

@module tests.ui.themes.init_spec
--]]

local Assert = require("support.assert")

local display = {}
package.preload["utils.settings"] = function()
    return { get = function(section) assert(section == "display"); return display end }
end
package.preload["ui.components.bookui"] = function()
    return { sz = function(n) return math.max(1, n * 2) end }
end

local Theme = require("ui.themes.init")

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

Assert.errors(function() Theme.get("neon") end, "unknown ui theme")

-- px：0 不被 UI.sz 抬成 1px。
Assert.eq(Theme.px(0), 0)
Assert.eq(Theme.px(3), 6)

return true
