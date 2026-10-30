--[[-- 锁屏设置：改配置先让出重绘再合成，完成后刷新预览叠层。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end

local log = {}
local scheduled = {}
local ticks = {}
package.preload["ui/uimanager"] = function()
    return {
        tickAfterNext = function(_, fn) ticks[#ticks + 1] = fn end,
        show = function() end,
        scheduleIn = function(_, _delay, fn) scheduled[#scheduled + 1] = fn end,
    }
end
package.preload["ui/network/manager"] = function() return {} end

local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o)
    if o.kind == "toast" then log[#log + 1] = "show:" .. o.text end
end
package.preload["ui.themes.widgets.row"] = function()
    local Row = { widget = function(opts) return opts end }
    -- 单选行替身：点按弹主题列表，选了别的值才回调（与 Row.choice 同约定，row_spec 测真实现）
    function Row.choice(opts)
        opts.callback = function()
            require("ui.themes.widgets.list"):new{
                title = opts.title, items = opts.items, current = opts.current,
                on_select = function(v) if v ~= nil and v ~= opts.current then opts.on_select(v) end end,
            }:show()
        end
        return opts
    end
    return Row
end

local refresh_cb
local running = false
package.preload["features.lockscreen"] = function()
    return {
        refresh = function(cb) log[#log + 1] = "refresh"; refresh_cb = cb; running = true end,
        running = function() return running end,
    }
end
local has_ads = false
local remove_ok, rebooted = true, 0
os.execute = function(cmd) if cmd == "reboot" then rebooted = rebooted + 1 end end
_G.G_reader_settings = { flush = function() end }
package.preload["features.lockscreen.settings"] = function()
    return {
        isCompose = function() return true end,
        hasAds = function() return has_ads end,
        removeAds = function() return remove_ok end,
        setBackgroundMode = function(value) log[#log + 1] = "set:" .. value end,
        setPosterStyle = function(value) log[#log + 1] = "poster:" .. value end,
        setPosterSort = function(value) log[#log + 1] = "sort:" .. value end,
        setCustomImage = function(value) log[#log + 1] = "image:" .. value end,
        setFolder = function(value) log[#log + 1] = "folder:" .. value end,
        setTypoFont = function(id) log[#log + 1] = "font:" .. id end,
    }
end
local component_id = "current"
local background_mode = "bing"
local chooser
package.preload["ui.themes.widgets.path_picker"] = function()
    return { new = function(_self, opts) chooser = opts; opts.show = function() end; return opts end }
end
package.preload["apps/filemanager/filemanagerutil"] = function()
    return { getHomeFolder = function() return "/home" end }
end
package.preload["features.lockscreen.poster"] = function()
    return {
        style = function() return "vertical" end,
        styleLabel = function() return "竖屏排版" end,
        styleOptions = function() return {} end,
        sort = function() return "recent_read" end,
        sortLabel = function() return "最近阅读" end,
        sortOptions = function()
            return {
                { text = "最近阅读", value = "recent_read" },
                { text = "最近添加", value = "recent_added" },
            }
        end,
    }
end
package.preload["features.lockscreen.compose"] = function()
    return { plan = function()
        return {
            component = { id = component_id, supports_position = false }, background_mode = background_mode,
            position = "center-center", wide = true, offline = true,
        }
    end }
end
package.preload["features.lockscreen.background"] = function()
    return {
        label = function(v) return v end,
        options = function() return {} end,
        customImage = function() return "/nonexistent/custom.png" end,
        folder = function() return "/" end,
    }
end
package.preload["features.lockscreen.components.base"] = function()
    return { options = function() return {} end }
end
package.preload["features.lockscreen.layout"] = function()
    return {
        label = function(v) return v end,
        options = function() return {} end,
        portraitSize = function() return 600, 800 end,
    }
end
package.preload["features.lockscreen.components.bill"] = function() return {} end
package.preload["utils.text"] = function() return {} end

local Lockscreen = require("features.lockscreen.page")

local overlay_updates = 0
local desktop = {
    updateView = function() log[#log + 1] = "desktop.updateView" end,
    settings_overlay = { updateView = function() overlay_updates = overlay_updates + 1 end },
}

has_ads = true
local ad_rows = Lockscreen:rows(desktop)
Assert.len(ad_rows, 4, "广告版 Kindle 多一行去广告提醒")
ad_rows[2]({}).callback()
local ad_confirm = Themed.last("confirm")
remove_ok = false
ad_confirm.ok_callback()
Assert.matches(Themed.last("toast").text, "moon.ankio.net/jailbreak/ads")
Assert.eq(rebooted, 0)
remove_ok = true
ad_confirm.ok_callback()
Assert.eq(#scheduled, 1)
scheduled[1]()
Assert.eq(rebooted, 1)
log = {}
has_ads = false

local rows = Lockscreen:rows(desktop)
Assert.len(rows, 3, "非海报墙背景没有「海报风格」行")
rows[2]({}).callback()
local popup = Themed.last("list")
Assert.not_nil(popup)
popup.on_select("folder")

-- 点击回调内只改配置、刷视图、弹提示；合成推到下一帧重绘之后。
Assert.eq(table.concat(log, ","), "set:folder,desktop.updateView,show:正在生成锁屏图…")
Assert.len(ticks, 1)

ticks[1]()
Assert.eq(log[#log], "refresh")
Assert.eq(overlay_updates, 1, "在飞时预览切到「生成中」")

running = false
refresh_cb(true)
Assert.eq(overlay_updates, 2, "完成后刷新预览")
Assert.eq(log[#log], "show:锁屏图已更新")

-- 叠层已关闭：完成回调不再碰叠层。
desktop.settings_overlay = nil
refresh_cb(false, "boom")
Assert.eq(log[#log], "show:生成失败: boom")

-- 海报墙背景：背景下面多「海报风格」「海报排序」，选中后写配置并走同一条刷新链路。
background_mode = "poster"
local poster_rows = Lockscreen:rows(desktop)
Assert.len(poster_rows, 5)
local style_row = poster_rows[3]({})
Assert.eq(style_row.title, "海报风格")
Assert.eq(style_row.status, "竖屏排版")
style_row.callback()
popup = Themed.last("list")
Assert.eq(popup.current, "vertical")
ticks = {}
popup.on_select("vertical")
Assert.len(ticks, 0, "选中当前值不重出图")
popup.on_select("standard")
Assert.eq(log[#log - 2], "poster:standard")
Assert.len(ticks, 1)
local sort_row = poster_rows[4]({})
Assert.eq(sort_row.title, "海报排序")
Assert.eq(sort_row.status, "最近阅读")
sort_row.callback()
popup = Themed.last("list")
Assert.eq(popup.current, "recent_read")
ticks = {}
popup.on_select("recent_read")
Assert.len(ticks, 0, "选中当前排序不重出图")
popup.on_select("recent_added")
Assert.eq(log[#log - 2], "sort:recent_added")
Assert.len(ticks, 1)

-- 自定义背景：多一行「选择图片」，只列图片文件；所在目录不存在时从主目录开始。
component_id, background_mode = "current", "custom"
local custom_rows = Lockscreen:rows(desktop)
Assert.len(custom_rows, 4)
local pick = custom_rows[3]({})
Assert.eq(pick.title, "选择图片")
Assert.matches(pick.subtitle, "^/nonexistent/custom%.png · 600 × 800$")
pick.callback()
Assert.is_true(chooser.select_file)
Assert.eq(chooser.path, "/home")
Assert.is_true(chooser.filter("a.JPG"))
Assert.is_false(chooser.filter("a.epub"))
ticks = {}
chooser.on_select("/mnt/us/me.png")
Assert.eq(log[#log - 2], "image:/mnt/us/me.png")
Assert.len(ticks, 1, "选完立刻重出图")

-- 文件夹背景：「选择文件夹」从当前文件夹开始，只能选目录。
background_mode = "folder"
local folder_rows = Lockscreen:rows(desktop)
local folder_pick = folder_rows[3]({})
Assert.eq(folder_pick.title, "选择文件夹")
Assert.eq(folder_pick.subtitle, "/")
folder_pick.callback()
Assert.is_false(chooser.select_file)
Assert.eq(chooser.path, "/")
Assert.is_nil(chooser.filter)
chooser.on_select("/mnt/us/walls")
Assert.eq(log[#log - 2], "folder:/mnt/us/walls")

-- 文字海报：「选择字体…」只打开字体选择器，选定字体后才写配置并重出图。
local picker
package.preload["ui.widgets.fontpicker"] = function() return { open = function(opts) picker = opts end } end
package.preload["features.lockscreen.typo"] = function()
    return {
        style = function() return "random" end, styleLabel = function() return "随机" end,
        styleOptions = function() return {} end, fontId = function() return "" end,
        fontLabel = function() return "自动" end,
    }
end
background_mode = "typo"
local font_row = Lockscreen:rows(desktop)[4]({})
Assert.eq(font_row.title, "海报字体")
font_row.callback()
ticks, log = {}, {}
Themed.last("list").on_select("pick")
Assert.not_nil(picker)
Assert.len(ticks, 0, "打开字体选择器时不重出图")
Assert.len(log, 0)
picker.on_select({}, "syst", "思源宋体")
Assert.eq(log[1], "font:syst")
Assert.len(ticks, 1, "选定字体后才重出图")

return true
