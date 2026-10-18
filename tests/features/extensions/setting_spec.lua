--[[--
features.extensions.setting：设置页分节「底栏 / 用户插件 / KOReader 自带」；没有自带入口时不出自带分节，
没有用户插件时用户分节给一行置灰提示；点行切换显示并刷新桌面。
@module tests.features.extensions.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, need-check-nil

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(s) return s end end
local cfg = { enabled = false, shown = {}, pin_mode = false }
package.preload["utils.settings"] = function()
    return { get = function() return cfg end, save = function() end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local entries, toggled, pinned_calls, pin_ok = {}, {}, {}, true
package.preload["features.extensions"] = function()
    return {
        entries = function() return entries end,
        isShown = function(e) return not e.builtin end,
        toggle = function(e) toggled[#toggled + 1] = e.id end,
        MAX_PINNED = 2,
        pinIcon = function() return "star" end,
        isPinned = function(e) return e.id == "a:a" end,
        togglePin = function(e) pinned_calls[#pinned_calls + 1] = e.id; return pin_ok end,
    }
end

local Setting = require("features.extensions.setting")
local updates = 0
local desktop = { plugin = {}, cellCapacity = function() return 2 end, updateView = function() updates = updates + 1 end }

local function build()
    local out = {}
    for _, section in ipairs(Setting.entries(desktop)[1].page.sections()) do
        local rows = {}
        for _, row in ipairs(section.rows) do rows[#rows + 1] = row(100) end
        out[#out + 1] = { title = section.title, rows = rows }
    end
    return out
end

do -- 没开固定：只有底栏 / 用户插件 / 自带三节，所有入口都在菜单分节里
    entries = {
        { id = "a:a", text = "A", builtin = false },
        { id = "b:b", text = "B", builtin = false },
        { id = "calibre:calibre", text = "Calibre", builtin = true },
    }
    local sections = build()
    Assert.len(sections, 3)
    Assert.len(sections[1].rows, 2)
    Assert.eq(sections[1].rows[2].toggle, false)
    Assert.len(sections[2].rows, 2)
    Assert.eq(sections[3].title, "KOReader 自带")
    sections[3].rows[1].callback()
    Assert.eq(toggled[1], "calibre:calibre")
    sections[1].rows[2].callback()
    Assert.eq(cfg.pin_mode, true, "固定开关落到配置")
end

do -- 开了固定：多出选择分节（固定入口后面跟图标行），已固定的入口不再出现在菜单分节
    entries = {
        { id = "a:a", text = "A", builtin = false },
        { id = "b:b", text = "B", builtin = false },
    }
    local sections = build()
    Assert.len(sections, 3)
    Assert.eq(sections[2].title, "选择固定的入口")
    Assert.len(sections[2].rows, 3, "两个入口 + 已固定入口的图标行")
    Assert.eq(sections[2].rows[1].toggle, true)
    Assert.eq(sections[2].rows[2].status, "star")
    Assert.eq(sections[2].rows[3].toggle, false)
    sections[2].rows[3].callback()
    Assert.eq(pinned_calls[1], "b:b")
    Assert.len(sections[3].rows, 1, "A 已固定，不在菜单分节")
    Assert.eq(sections[3].rows[1].title, "B")
end

do -- 只有自带：用户分节一行置灰提示
    cfg.pin_mode = false
    entries = { { id = "calibre:calibre", text = "Calibre", builtin = true } }
    local sections = build()
    Assert.len(sections[2].rows, 1)
    Assert.eq(sections[2].rows[1].enabled, false)
end
