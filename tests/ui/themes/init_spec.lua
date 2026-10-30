--[[--
ui.themes：三套令牌键集合与取值类型一致、灰度合法；当前主题读 display.ui_theme，未设或写错回落 paper。

@module tests.ui.themes.init_spec
--]]

local Assert = require("support.assert")

local display = {}
local color_enabled = false
local rgb_channels = {}
package.preload["ffi/blitbuffer"] = function()
    return {
        Color8 = function(value) return value end,
        ColorRGB32 = function(r, g, b)
            rgb_channels = { r, g, b }
            return rgb_channels
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function(section) assert(section == "ui"); return display end,
        save = function() end,
    }
end
package.preload["device"] = function()
    return { screen = {
        scaleBySize = function(_, n) return n * 2 end,
        isColorEnabled = function() return color_enabled end,
    } }
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

-- 彩色模式只替换交互强调色，关闭后恢复原始令牌；不污染共享灰度主题。
color_enabled = true
for _idx, id in ipairs(Theme.ids) do
    Theme.set(id)
    local t, base_tokens = Theme.current(), Theme.get(id)
    Assert.is_true(t.button.primary.bg > 255)
    Assert.eq(t.selected.bg, base_tokens.selected.bg == 0 and t.color.accent or base_tokens.selected.bg,
        "选中底色保留各主题差异，仅实心黑底换为强调色")
    Assert.eq(t.selected.ink, base_tokens.selected.ink == 0 and t.color.accent or base_tokens.selected.ink)
    Assert.is_true(t.progress.fill > 255)
    Assert.eq(t.color.ink, base_tokens.color.ink, "正文保持黑色")
    Assert.eq(t.raised.bg, base_tokens.raised.bg, "通用凸起表面不染色，避免污染封面容器")
    Assert.eq(t.button.normal.bg, base_tokens.button.normal.bg, "选择器及普通按钮保留原灰度底色")
    Assert.eq(t.control, base_tokens.control, "几何不变")
    Assert.eq(Theme.current(), t, "彩色令牌复用，不逐帧分配")
    Assert.eq(base_tokens.button.primary.bg, 0)
    color_enabled = false
    Assert.eq(Theme.current(), base_tokens)
    color_enabled = true
end
Theme.color(0x245B78)
Assert.eq(rgb_channels[1], 0x24)
Assert.eq(rgb_channels[2], 0x5B)
Assert.eq(rgb_channels[3], 0x78)
Assert.eq(Theme.color(0x88), 0x88)
Assert.eq(Theme.mix(0xFF, 0, 0.5), 0x80)
Assert.eq(Theme.mix(0xFF, 0x0756AD, 1), 0x0756AD)
-- 彩屏补饱和：灰度与等通道色不动，主题色绕均值拉开色差，掺灰的派生色也补回来。
Assert.eq(Theme.vivid(0x88), 0x88)
Assert.eq(Theme.vivid(0x808080), 0x808080)
Assert.eq(Theme.vivid(0x0756AD), 0x0054E8)
Assert.eq(Theme.mix(0xEE, 0x0054E8, 0.25), 0xA1C4FF, "低档热力色不被掺成灰")
display.theme_color = 0x7038A0
local purple = Theme.current()
local vivid_purple = Theme.vivid(display.theme_color)
Assert.eq(purple.color.accent, vivid_purple, "存量主题色经补饱和后派生，不迁移配置")
Assert.eq(purple.progress.fill, vivid_purple, "统计只能使用同一主题色")
Assert.eq(purple.selected.ink, vivid_purple)
Assert.eq(purple.button.primary.bg, vivid_purple)
Assert.eq(purple.button.ghost.ink, vivid_purple)
display.theme_color = 0x00734F
Assert.eq(Theme.current().color.accent, Theme.vivid(display.theme_color), "改色后缓存失效")
Assert.eq(purple.color.accent, vivid_purple, "旧控件持有的令牌不原地修改")
-- 色板是单色主题：全场一个颜色，语义别名令牌恒等于 accent（分角色实测看不出区别）。
display.theme_preset = "sakura"
local sakura = Theme.current()
Assert.eq(sakura.color.accent, Theme.vivid(0xA34454))
Assert.is_nil(sakura.color.icons, "别名令牌已删：只有 accent 一色")
Assert.eq(sakura.progress.fill, sakura.color.accent)
Assert.eq(sakura.selected.ink, sakura.color.accent)
Assert.eq(sakura.card.border_color, sakura.color.accent)
Assert.eq(sakura.button.primary.ink, 0xFF, "深色主按钮用白字")
display.theme_preset = "ink"
local ink = Theme.current()
Assert.eq(ink.color.accent, 0, "墨黑不补饱和")
Assert.eq(ink.button.primary.bg, 0)
Assert.eq(ink.button.primary.ink, 0xFF, "黑底主按钮用白字")
Assert.is_true(Theme.colorful())
Assert.eq(Theme.chrome(), 0, "彩色开着时 chrome 就是 accent，含墨黑")
display.theme_preset = nil
display.theme_color = 0xFFCC00
Assert.eq(Theme.current().button.primary.ink, 0, "亮色主按钮用黑字")
Assert.eq(Theme.current().color.accent, Theme.vivid(0xFFCC00), "没选色板时回到单色展开")
color_enabled = false
Assert.eq(Theme.current().color.accent, 0, "灰度模式强调色就是墨色")
Assert.eq(Theme.current(), Theme.get(Theme.id()), "关彩色后不受主题色影响")
Assert.is_false(Theme.colorful())
Assert.eq(Theme.chrome(), Theme.get(Theme.id()).color.muted, "关彩色 chrome 回落 muted")
local screen = require("device").screen
screen.isColorEnabled = nil
Assert.eq(Theme.current(), Theme.get(Theme.id()), "旧屏幕没有彩色查询接口时保持灰度")

return true
