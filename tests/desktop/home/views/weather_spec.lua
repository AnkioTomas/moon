--[[--
天气：读 online.weather，成功才刷；同 URL 复用图标框；暂停撤定时并丢掉图标；设置框地名只收英文。
@module tests.desktop.pages.home.weather_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

Kit.sections.home = { home_weather_city = "Shanghai" }
package.preload["utils.text"] = function()
    return { trim = function(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end }
end
local fetch_cb, fetch_args, watch_cb, unwatched, cancelled, ensures = nil, nil, nil, 0, 0, 0
local ICON_URL = "https://cdn.example/weather/"
package.preload["online.weather"] = function()
    return {
        iconUrl = function(key) return ICON_URL .. key .. ".png" end,
        current = function() return nil end,
        watch = function(_, cb) watch_cb = cb end,
        ensure = function() ensures = ensures + 1 end,
        unwatch = function() unwatched = unwatched + 1 end,
        fetch = function(_, args, cb)
            fetch_args, fetch_cb = args, cb
            return { cancel = function() cancelled = cancelled + 1 end }
        end,
    }
end

local Weather = require("desktop.pages.home.weather")
local ctx = { desktop = {} }
local opts = { width = 400, height = 96 }
local FULL = {
    temp = "26", desc = "阴", city = "上海", low = "18", high = "28", feels = "25",
    humidity = "62", wind = "北", wind_kmph = "12", icon = "overcast", image = "https://cdn.example/w.png",
}
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

do -- 空态：多云占位 + --°；失败不改字也不刷新
    local weather = Weather:new()
    local slot = weather:build(ctx, opts)
    Assert.eq(table.concat(Kit.texts(slot), "|"), "--°|--|--")
    Assert.eq(weather.picture.src, ICON_URL .. "cloud.png")
    Assert.is_nil(watch_cb, "构建不挂订阅")
    slot:paintTo(Kit.canvas(), 0, 10)
    weather:activate()
    Assert.not_nil(watch_cb)
    Assert.eq(ensures, 1)
    Assert.len(Kit.scheduled, 1, "恢复起整点定时")
    watch_cb({}, "network")
    Assert.eq(weather.temp.text, "--°")
    Assert.len(Kit.dirty, 0, "内容与图标未变，恢复与失败都不刷新")
    weather:deactivate()
    Assert.eq(unwatched, 1, "暂停摘等待")
    Assert.eq(cancelled, 0, "暂停不取消 online 刷新")
    weather:destroy()
end

do -- 成功补温度和图；同内容新表不刷新；暂停丢图标框；有温度没图按 icon 回退 CDN
    Kit.dirty, watch_cb, unwatched, cancelled, ensures = {}, nil, 0, 0, 0
    local weather = Weather:new()
    local slot = weather:build(ctx, opts)
    slot:paintTo(Kit.canvas(), 0, 10)
    weather:activate()
    watch_cb(copy(FULL))
    Assert.eq(weather.temp.text, "26°")
    Assert.eq(weather.detail.text, "阴 · 上海 · 18–28°")
    Assert.eq(weather.extra.text, "体感 25° · 湿度 62% · 北风 12km/h")
    Assert.eq(weather.picture.src, FULL.image)
    Assert.eq(weather.hero[1], weather.picture)
    Assert.eq(weather.hero[3], weather.temp)
    Assert.len(Kit.dirty, 1)
    local first = weather.picture
    weather:pull()
    Assert.eq(ensures, 2, "pull 只 ensure，不强制刷")
    watch_cb(copy(FULL))
    Assert.eq(weather.picture, first, "同 URL 复用当前框")
    Assert.len(Kit.dirty, 1, "缓存命中同内容新表不刷新")
    weather:onEvent("home_refresh")
    Assert.eq(ensures, 3, "首页刷新再 ensure")
    weather:deactivate()
    Assert.is_nil(weather.picture, "暂停丢掉图标引用")
    Assert.is_true(first[1].cancelled)
    Assert.eq(cancelled, 0, "暂停不取消 online 刷新")
    weather:activate()
    Assert.not_nil(weather.picture, "恢复重新挂图标")
    Assert.is_true(weather.picture ~= first)
    watch_cb({ temp = "18", icon = "sunny", sunrise = "06:12 AM", sunset = "06:40 PM" })
    Assert.eq(weather.picture.src, ICON_URL .. "sunny.png")
    Assert.eq(weather.extra.text, "日出 06:12 AM · 日落 06:40 PM")
    local tick = weather._tick
    weather:destroy()
    Assert.eq(Kit.unscheduled[#Kit.unscheduled], tick)
    Assert.is_nil(weather.temp)
end

do -- 设置：中文地名拒绝后带原输入重开；测试按钮试查不保存；保存后通知首页刷新
    Kit.sections.home.home_weather_city = ""
    local events = {}
    local desktop = { onEvent = function(_, e) events[#events + 1] = e end }
    Weather:showSettings(desktop)
    local dialog = Themed.last("input")
    Assert.eq(dialog.title, "天气地点")
    Assert.eq(dialog.fields[1].text, "")
    dialog.callback("上海")
    Assert.eq(Themed.last("toast").text, "请用英文字母填写地名，例如 Shanghai")
    local reopened = Themed.last("input")
    Assert.is_true(reopened ~= dialog)
    Assert.eq(reopened.fields[1].text, "上海")

    fetch_cb = nil
    reopened.actions[1].callback("上海")
    Assert.is_nil(fetch_cb, "中文不试查")
    reopened.actions[1].callback(" Shanghai ")
    Assert.eq(fetch_args.city, "Shanghai")
    Assert.eq(fetch_args.ttl, 0)
    local probe_cb = fetch_cb
    fetch_cb = nil
    reopened.actions[1].callback("Shanghai")
    Assert.is_nil(fetch_cb, "试查中不重复发")
    probe_cb({ temp = "26", city = "Shanghai", desc = "阴" })
    Assert.eq(Themed.last("toast").text, "Shanghai · 26° · 阴")
    reopened.actions[1].callback("Beijing")
    Assert.eq(fetch_args.city, "Beijing", "试查结束可再测")
    fetch_cb({})
    Assert.eq(Themed.last("toast").text, "测试失败：没有查到天气")
    reopened.actions[1].callback("Xiamen")
    fetch_cb(nil)
    Assert.eq(Themed.last("toast").text, "测试失败：没有查到天气")
    Assert.eq(Kit.sections.home.home_weather_city, "", "测试不保存")

    reopened.callback("Shanghai")
    Assert.eq(Kit.sections.home.home_weather_city, "Shanghai")
    Assert.eq(events[1], "home_refresh")
end
