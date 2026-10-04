--[[--
翻页动画设置：reader 分组入口，开关装/卸补丁，开启时多一行风格。

@module tests.features.animation.setting_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return {
        template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return {
        new = function(_, opts)
            return { show = function() toasts[#toasts + 1] = opts.text end }
        end,
    }
end

local enabled, set_result, restarts, on_change = false, { ok = true }, 0, nil
local style = { text = "擦除", value = "wipe" }
package.preload["features.animation"] = function()
    return {
        isEnabled = function() return enabled end,
        setEnabled = function(on)
            if set_result.ok then enabled = on end
            return set_result
        end,
        promptRestart = function() restarts = restarts + 1 end,
        currentStyle = function() return style end,
        pickStyle = function(cb) on_change = cb end,
    }
end

local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }
local Setting = require("features.animation.setting")

local entries = Setting.entries(desktop)
Assert.len(entries, 1)
local entry = entries[1]
Assert.eq(entry.group, "reader")
Assert.eq(entry.title, "翻页动画")
Assert.eq(entry.status, "关")
Assert.is_false(entry.status_on)

-- 关闭时只有开关一行。
local rows = entry.page.sections()[1].rows
Assert.len(rows, 1)
local toggle = rows[1](600)
Assert.eq(toggle.kind, "toggle")
Assert.is_false(toggle.status_on)

-- 补丁失败：提示错误，不刷新、不提示重启。
set_result = { ok = false, err = "anchor not found" }
toggle.callback()
Assert.eq(toasts[1], "翻页动画补丁操作失败：anchor not found")
Assert.eq(updates, 0)
Assert.eq(restarts, 0)
Assert.is_false(enabled)

-- 成功：刷新并提示重启。
set_result = { ok = true }
toggle.callback()
Assert.is_true(enabled)
Assert.eq(updates, 1)
Assert.eq(restarts, 1)

-- 开启后多一行风格，显示当前风格名；选中后刷新设置页。
Assert.eq(Setting.entries(desktop)[1].status, "开")
rows = entry.page.sections()[1].rows
Assert.len(rows, 2)
local style_row = rows[2](600)
Assert.eq(style_row.title, "翻页动画风格")
Assert.eq(style_row.status, "擦除")
style_row.callback()
on_change()
Assert.eq(updates, 2)
style = { text = "方框", value = "box" }
Assert.eq(entry.page.sections()[1].rows[2](600).status, "方框")

return true
