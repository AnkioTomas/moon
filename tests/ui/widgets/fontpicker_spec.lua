--[[--
fontpicker：主题 List 分栏；无系统默认行；预览按页懒构建；当前字体是选中项。

@module tests.ui.widgets.fontpicker_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local getface_n = 0
local image_n = 0
local last_image
local selected
local prepare_callback, prepare_cancelled

package.preload["ui/font"] = function()
    return {
        fontmap = {},
        -- 只数字体文件预览；主题文字 / 图标字体也走 getFace。
        getFace = function(_, id)
            if id:match("%.ttf$") then getface_n = getface_n + 1 end
            return { id = id }
        end,
    }
end
package.loaded["ui/font"] = nil

-- 只数预览图构建次数；主题图片外观另有 image_spec。
package.preload["ui.themes.widgets.image"] = function()
    return {
        widget = function(o)
            image_n = image_n + 1
            last_image = o
            return { _src = o.src, getSize = function() return { w = o.width, h = o.height } end,
                paintTo = function() end }
        end,
    }
end

package.preload["ui/network/manager"] = function()
    return { runWhenConnected = function(_, cb) cb() end }
end

package.preload["ui.fonts"] = function()
    return {
        currentId = function() return "Font25.ttf" end,
        -- set 成功须返回真值；fontpicker 按 ok 决定 Toast「已选择」还是「无法打开」。
        set = function(id) selected = id; return true end,
        downloadedPath = function(id) return id:match("^wr") and "/fonts/" .. id .. ".ttf" end,
    }
end
package.preload["ui.fonts.catalog"] = function()
    local items = {}
    for i = 1, 40 do
        items[#items + 1] = {
            id = string.format("Font%02d.ttf", i),
            name = string.format("Font%02d", i),
            kind = "local",
        }
    end
    for i = 1, 3 do
        items[#items + 1] = {
            id = string.format("Sys%d.ttf", i),
            name = "Sys" .. i,
            kind = "system",
        }
    end
    for i = 1, 20 do
        items[#items + 1] = {
            id = "wr" .. i,
            name = "Weread" .. i,
            kind = "weread",
            preview = "https://example.com/p" .. i .. ".svg",
            zip_size = 1000,
        }
    end
    return {
        -- 缓存命中时同步回调。
        listAsync = function(cb)
            cb(items)
            return { cancel = function() end }
        end,
        ensureInstalledAsync = function(_item, _progress, cb)
            prepare_callback = cb
            return { cancel = function() prepare_cancelled = true end }
        end,
    }
end
package.loaded["ui.fonts"] = nil
package.loaded["ui.fonts.catalog"] = nil
package.loaded["ui.widgets.fontpicker"] = nil

local FontPicker = require("ui.widgets.fontpicker")
FontPicker.open{ title = "字体" }

local list = Kit.shown[#Kit.shown]
Assert.eq(list.title, "字体")
Assert.eq(Kit.closed[1] ~= nil and Kit.closed[1].text, "正在加载字体列表…", "列表到了先关加载提示")

-- 当前字体在本地分栏第 25 项：默认打开本地分栏并翻到它所在页（每页 13 项，含底栏）。
Assert.eq(list.tabs.active, "local")
Assert.len(list.tabs.tabs, 4, "底部四个分栏：在线/用户/本地/系统")
Assert.len(list.items, 40, "本地 40 行，无系统默认行")
Assert.eq(list.items[1].text, "", "行只留预览，无名字列")
Assert.eq(list.page, math.ceil(25 / list.per_page))
Assert.len(Kit.find(list, function(w) return w.text == "radio_button_checked" end), 1, "当前字体是选中项")
Assert.is_true(getface_n >= 1 and getface_n <= list.per_page, "只构建当前页预览, got " .. getface_n)
Assert.eq(image_n, 0, "本地页不拉图")

-- 切到在线分栏：预览改走远程图，同样只建一页。
getface_n = 0
list:switchTab("weread")
Assert.eq(list.tabs.active, "weread")
Assert.len(list.items, 20)
Assert.eq(list.page, 1, "在线分栏没有当前项，停在第 1 页")
Assert.eq(image_n, list.per_page, "在线页懒构建预览图")
Assert.eq(getface_n, 0, "在线页不碰本地字体")
Assert.is_nil(last_image.style.bg, "预览图不画 image 表面灰底")
Assert.is_true(last_image.width <= math.floor(last_image.height * 90 / 24), "预览图按 90×24 比例定宽、靠左")

-- 用户分栏为空：一条禁用占位行。
list:switchTab("user")
Assert.len(list.items, 1)
Assert.is_false(list.items[1].enabled)

-- 系统字库单独一栏，预览走本地字体渲染。
getface_n = 0
list:switchTab("system")
Assert.len(list.items, 3)
Assert.eq(list.items[1].value.id, "Sys1.ttf")
Assert.eq(getface_n, 3, "系统页用字体本身渲染预览")

-- 选中已安装字体：关列表、写设置、提示。
list:switchTab("local")
Kit.taps(list)[1]:onTapThemeArea()
Assert.eq(Kit.closed[#Kit.closed], list, "选中即关列表")
Assert.is_true(selected ~= nil and selected:match("^Font%d+%.ttf$") ~= nil, "写入选中字体")
Assert.eq(Kit.shown[#Kit.shown].text, "已选择：" .. selected:gsub("%.ttf$", ""))

-- 已下载在线字体选「使用」也先异步准备，不联网、不提前写设置。
selected = nil
FontPicker.open{ title = "字体" }
list = Kit.shown[#Kit.shown]
list:switchTab("weread")
list.on_select(list.items[1].value)
local sheet = Kit.shown[#Kit.shown]
Assert.eq(sheet.items[1].text, "使用")
sheet.items[1].callback()
local preparing = Kit.shown[#Kit.shown]
Assert.eq(preparing.title, "正在准备字体 Weread1")
Assert.is_nil(selected)
prepare_callback(true)
Assert.eq(selected, "wr1")
Assert.is_nil(prepare_cancelled, "正常完成关进度窗不取消任务")

selected = nil
sheet.items[1].callback()
preparing = Kit.shown[#Kit.shown]
preparing:close()
Assert.is_true(prepare_cancelled, "关闭进度窗取消准备任务")
prepare_callback(true)
Assert.is_nil(selected, "关闭后迟到的完成回调不能应用字体")

FontPicker.open{ title = "西文字体", initial_tab = "system", current_id = function() return "" end }
Assert.eq(Kit.shown[#Kit.shown].tabs.active, "system", "首次选西文字体直接打开系统字库")
FontPicker.open{ initial_tab = "system", current_id = function() return "Font25.ttf" end }
Assert.eq(Kit.shown[#Kit.shown].tabs.active, "local", "已选字体仍优先定位到所在分栏")

return true
