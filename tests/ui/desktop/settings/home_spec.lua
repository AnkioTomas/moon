--[[-- 首页设置：天气 + 在首页编辑入口；组件只读摘要。 --]]

local Assert = require("support.assert")

local placements = {
    { id = "recent_hero", page = 1, order = 1, height = "default" },
    { id = "recent_list", page = 1, order = 2, height = "fill" },
}
local home = {
    home_widgets = placements,
}
local saves = 0
local shown
local edit_calls = 0

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return {
        template = function(text, a, b)
            local out = text:gsub("%%1", tostring(a), 1)
            if b ~= nil then out = out:gsub("%%2", tostring(b), 1) end
            return out
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        saveSection = function(_, values)
            home = values
            saves = saves + 1
        end,
    }
end
package.preload["ui.desktop.home.registry"] = function()
    local components = {
        { id = "recent_hero", label = "当前阅读", icon = "auto_stories" },
        { id = "recent_list", label = "最近阅读列表", icon = "view_list" },
        { id = "clock", label = "时钟", icon = "schedule" },
        { id = "clock_weather", label = "时间天气", icon = "nest_clock_farsight_analog" },
    }
    return {
        components = components,
        widgets = function() return placements end,
        find = function(id)
            for _, component in ipairs(components) do
                if component.id == id then return component end
            end
        end,
    }
end
package.preload["ui.desktop.home.views.clock_weather"] = function()
    return {
        ORDER_WEATHER = "weather_left",
        ORDER_CLOCK = "clock_left",
        order = function()
            return home.home_clock_weather_order == "clock_left" and "clock_left" or "weather_left"
        end,
        orderLabel = function()
            return home.home_clock_weather_order == "clock_left" and "时间在左" or "天气在左"
        end,
        saveOrder = function(value)
            home.home_clock_weather_order = value
            saves = saves + 1
        end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/inputdialog"] = function()
    return {
        new = function(_, opts)
            opts.getInputText = function() return opts.input or "" end
            opts.onShowKeyboard = function() end
            return opts
        end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
local weather_cb
package.preload["online.weather"] = function()
    return {
        fetch = function(_, args, cb)
            weather_cb = { city = args.city, ttl = args.ttl, cb = cb }
            return { cancel = function() end }
        end,
    }
end
package.preload["utils.text"] = function()
    return {
        trim = function(s)
            return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown = widget end,
        close = function() end,
    }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end

local Settings = require("ui.desktop.settings.home")
local events = {}
local view_updates = 0
local desktop = {
    onEvent = function(_, event)
        events[#events + 1] = event
    end,
    updateView = function()
        view_updates = view_updates + 1
    end,
    switchTab = function(_, id)
        events[#events + 1] = "tab:" .. id
    end,
    home = {
        enterEdit = function()
            edit_calls = edit_calls + 1
        end,
    },
}

local function sectionByTitle(sections, title)
    for _, section in ipairs(sections) do
        if section.title == title then return section end
    end
end

local sections = Settings.new():sections(desktop)
local edit_section = sectionByTitle(sections, "首页组件")
Assert.not_nil(edit_section)
local edit_row = edit_section.rows[1](600)
Assert.eq(edit_row.title, "在首页编辑")
edit_row.callback()
Assert.eq(events[1], "tab:home")
Assert.eq(edit_calls, 1)

local placed = sectionByTitle(sections, "已放置组件")
Assert.len(placed.rows, 2)
local row = placed.rows[1](600)
Assert.is_true(row.status:find("第 1 页", 1, true) ~= nil)

placements = {
    { id = "clock_weather", page = 2, order = 1, height = 80 },
}
home.home_widgets = placements
home.home_clock_weather_order = "weather_left"
sections = Settings.new():sections(desktop)
local cw = sectionByTitle(sections, "时间天气")
Assert.not_nil(cw)
local order_row = cw.rows[1](600)
Assert.eq(order_row.status, "天气在左")
local saves_order = saves
order_row.callback()
Assert.eq(home.home_clock_weather_order, "clock_left")
Assert.is_true(saves > saves_order)

local data = sectionByTitle(Settings.new():sections(desktop), "首页数据")
local city_row = data.rows[1](600)
Assert.eq(city_row.title, "天气地点")
Assert.eq(city_row.status, "按 IP 定位")
city_row.callback()
Assert.eq(shown.description, "留空按 IP 定位。填写请用英文字母，例如 Shanghai。")
Assert.eq(shown.buttons[1][2].text, "测试")
shown.input = "上海"
shown.buttons[1][2].callback()
Assert.is_nil(weather_cb)
Assert.eq(shown.text, "请用英文字母填写地名，例如 Shanghai")
city_row.callback()
shown.input = "Shanghai"
shown.buttons[1][2].callback()
Assert.eq(weather_cb.city, "Shanghai")
Assert.eq(weather_cb.ttl, 0)
weather_cb.cb({ temp = "26", city = "Shanghai", desc = "阴" })
Assert.eq(shown.text, "Shanghai · 26° · 阴")

return true
