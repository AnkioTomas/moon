--[[-- 夜间与亮度设置行：自动夜间一行，有前光时再加自动亮度一行；亮度菜单常开就地刷新；定时拒绝空夜间。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local Themed = require("support.theme_stubs")
Themed.install()

local frontlight = true
package.preload["device"] = function()
    return { hasFrontlight = function() return frontlight end }
end
local night_window
local conf = {
    auto_light = false,
    auto_night_from = 22 * 60, auto_night_to = 7 * 60,
    auto_light_periods = { 5, 12, 22, 30, 27, 18, 10, 5 },
}
local saves = 0
package.preload["utils.settings"] = function()
    return {
        get = function(name)
            assert(name == "features.nightmode")
            conf.auto_night = night_window and "schedule" or "off"
            return conf
        end,
        save = function(name, values)
            assert(name == "features.nightmode")
            assert(values == nil, "就地改的表直接 save(owner)")
            saves = saves + 1
        end,
    }
end
local applied, modes = 0, {}
package.preload["features.nightmode"] = function()
    return {
        PERIOD_STARTS = { 0, 300, 480, 660, 780, 1020, 1140, 1320 },
        window = function() if night_window then return night_window[1], night_window[2] end end,
        hasSensor = function() return false end,
        setLight = function(on) conf.auto_light = on end,
        applyLight = function() applied = applied + 1 end,
        setMode = function(mode) modes[#modes + 1] = mode end,
    }
end

package.loaded["features.nightmode.page"] = nil
local Page = require("features.nightmode.page")
local views = 0
local desktop = { updateView = function() views = views + 1 end }
local rows = Page.rows(desktop)
Assert.len(rows, 2)
Assert.eq(rows[1](600).title, "自动夜间模式")
Assert.eq(rows[1](600).status, "关")
Assert.is_false(rows[1](600).status_on)
night_window = { 22 * 60, 7 * 60 }
Assert.eq(rows[1](600).status, "22:00–07:00")
Assert.is_true(rows[1](600).status_on)
Assert.eq(rows[2](600).title, "自动亮度")
Assert.eq(rows[2](600).status, "关")
Assert.is_false(rows[2](600).status_on)
Assert.eq(rows[2](600).subtitle, "按时段和天气调节；手动调亮度会关闭自动亮度")

-- 亮度菜单：每项 keep_open，改完不关窗、就地刷新右侧数值与开关文案。
rows[2](600).callback()
local list = Themed.last("list")
Assert.len(list.items, 9, "开关 + 8 个时段")
for _idx, item in ipairs(list.items) do Assert.is_true(item.keep_open) end
Assert.eq(list.items[2].mandatory, "5%")
Themed.choose(list, 2)
Themed.last("spin").callback(40)
Assert.eq(conf.auto_light_periods[1], 40)
Assert.eq(saves, 1)
Assert.eq(applied, 1)
Assert.eq(list.items[2].mandatory, "40%")
Assert.is_nil(list.closed, "改一项不关菜单")
Assert.eq(list.items[1].text, "开启")
Themed.choose(list, 1)
Assert.is_true(conf.auto_light)
Assert.eq(list.items[1].text, "关闭")
Assert.eq(views, 2)

-- 定时：开始等于结束没有夜晚，拒绝保存并提示；不同则应用。
rows[1](600).callback()
local night_list = Themed.last("list")
Themed.choose(night_list, 2)
Themed.last("spin").callback(22, 0)
Themed.last("spin").callback(22, 0)
Assert.len(modes, 0)
Assert.eq(Themed.last("toast").text, "开始和结束时间相同，没有夜间时段")
Assert.eq(conf.auto_night_to, 7 * 60)

frontlight = false
Assert.len(Page.rows(desktop), 1, "无前光不展示自动亮度")
