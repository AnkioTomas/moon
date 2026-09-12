--[[--
天气：自己拉网；成功才刷；Pause 丢掉图片框。布局跟时钟同构，两行辅文。
@module tests.ui.desktop.home.views.weather_spec
--]]

local Assert = require("support.assert")

local function widget()
    return {
        new = function(_, opts)
            opts.getSize = function(self)
                return self.dimen or { w = 100, h = 40 }
            end
            opts.setText = function(self, text) self.text = text end
            return opts
        end,
    }
end

for _, name in ipairs({
    "container/centercontainer", "container/framecontainer",
    "horizontalgroup", "horizontalspan", "verticalgroup", "verticalspan",
    "textwidget",
}) do
    package.preload["ui/widget/" .. name] = widget
end
package.preload["ui/geometry"] = widget
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() end,
        muted = function() return 0 end,
        dim = function() return 0 end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return {
        template = function(s, a, b)
            s = s:gsub("%%1", tostring(a), 1)
            if b ~= nil then s = s:gsub("%%2", tostring(b), 1) end
            return s
        end,
    }
end
package.preload["utils.text"] = function()
    return { trim = function(s) return tostring(s or "") end }
end

local settings = { home_weather_city = "Shanghai" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end

local paints = 0
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() paints = paints + 1 end,
        scheduleIn = function(_, _sec, fn)
            scheduled[#scheduled + 1] = fn
        end,
        unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do
                if scheduled[i] == fn then table.remove(scheduled, i) end
            end
        end,
    }
end

local images = {}
package.preload["ui.components.image"] = function()
    return {
        widget = function(opts)
            local box = {
                src = opts.src,
                cancelled = false,
                cancel = function(self)
                    self.cancelled = true
                end,
            }
            images[#images + 1] = box
            return box
        end,
    }
end

local fetch_cb, fetch_args, cancelled
local ICON_URL = "https://cdn.example/weather/"
package.preload["online.weather"] = function()
    return {
        iconUrl = function(key)
            return ICON_URL .. tostring(key) .. ".png"
        end,
        fetch = function(_, args, cb)
            fetch_args = args
            fetch_cb = cb
            return { cancel = function() cancelled = (cancelled or 0) + 1 end }
        end,
    }
end

local Weather = require("ui.desktop.home.views.weather")
local ctx = { desktop = {} }
local opts = { width = 400, height = 96, y = 10 }
local empty_icon = ICON_URL .. "cloud.png"

do -- 默认空态：多云占位 + --°；失败不改字
    images, paints, scheduled, fetch_cb, cancelled = {}, 0, {}, nil, 0
    local weather = Weather:new()
    weather.home = {}
    weather:build(ctx, opts)
    Assert.eq(weather.temp.text, "--°")
    Assert.eq(weather.detail.text, "--")
    Assert.eq(weather.extra.text, "--")
    Assert.eq(weather.picture.src, empty_icon)
    Assert.len(images, 1, "空态多云占位")
    Assert.eq(weather.hero[3], weather.temp)
    weather:onResume()
    Assert.eq(fetch_args.city, "Shanghai")
    Assert.len(images, 1, "空占位同 src 复用")
    fetch_cb({}, "network")
    Assert.eq(weather.temp.text, "--°")
    Assert.eq(paints, 1, "Resume 脏一次，失败不再加")
    weather:onPause()
    Assert.eq(cancelled, 0, "已完成请求不应再登记为在飞任务")
    weather:onDestroy()
end

do -- 成功才补温度和彩图；同 URL 复用框；两行辅文
    images, paints, scheduled, fetch_cb = {}, 0, {}, nil
    local weather = Weather:new()
    weather.home = {}
    weather:onCreate()
    weather:onStart()
    local part = weather:build(ctx, opts)
    Assert.eq(part:getSize().h, 96)
    weather:onResume()
    fetch_cb({
        temp = "26",
        desc = "阴",
        city = "上海",
        low = "18",
        high = "28",
        feels = "25",
        humidity = "62",
        wind = "北",
        wind_kmph = "12",
        icon = "overcast",
        image = "https://cdn.example/w.png",
    })
    Assert.eq(weather.temp.text, "26°")
    Assert.eq(weather.detail.text, "阴 · 上海 · 18–28°")
    Assert.eq(weather.extra.text, "体感 25° · 湿度 62% · 北风 12km/h")
    Assert.eq(weather.picture.src, "https://cdn.example/w.png")
    Assert.eq(weather.hero[3], weather.temp, "有图时温度在主行右侧")
    local first = weather.picture
    weather:paint()
    Assert.eq(weather.picture, first, "同 URL 复用当前框")
    Assert.eq(#scheduled, 1)

    weather:onPause()
    Assert.is_nil(weather.picture, "Pause 必须丢掉图片引用")
    Assert.is_true(first.cancelled)
    Assert.eq(#scheduled, 0)

    local n = #images
    weather:onResume()
    Assert.eq(#images, n + 1, "Resume 必须新建图片框")
    Assert.eq(weather.picture, images[#images])
    fetch_cb({
        temp = "26",
        desc = "阴",
        city = "上海",
        icon = "overcast",
        image = "https://cdn.example/w.png",
    })
    Assert.eq(weather.picture, images[#images], "同一张框，成功回调不换")

    local before = #images
    weather:build(ctx, opts)
    Assert.eq(#images, before, "重复 build 必须复用骨架和图片框")
    Assert.eq(weather.picture, images[#images])

    weather._tick()
    Assert.not_nil(fetch_cb)

    weather:onPause()
    weather:onStop()
    weather:onDestroy()
    Assert.is_nil(weather.picture)
end

do -- 有温度没图：按 icon 键回退 CDN
    images, fetch_cb = {}, nil
    local weather = Weather:new()
    weather.home = {}
    weather:build(ctx, opts)
    weather:onResume()
    fetch_cb({ temp = "18", icon = "sunny", sunrise = "06:12 AM", sunset = "06:40 PM" })
    Assert.eq(weather.temp.text, "18°")
    Assert.eq(weather.picture.src, ICON_URL .. "sunny.png")
    Assert.eq(weather.extra.text, "日出 06:12 AM · 日落 06:40 PM")
    weather:onDestroy()
end

return true
