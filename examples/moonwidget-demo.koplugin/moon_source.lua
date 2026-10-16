--[[--
月读扩展示例：不是书源，只往首页加一个组件。契约见 examples/moonsource-demo.koplugin/moon_source.lua 头注释。

- provides.source = false：不进数据源列表，不需要 meta / new；id 写在描述表顶层，必须是 ext.<name>。
- home_widgets 用简写表：build(ctx, w, h) 返回占满 w × h 的控件；settings(desktop, id) 让首页编辑态出现设置按钮。
- 组件设置存进 utils.settings.getSource(<扩展 id>) 那张独立表（settings/<id>.lua），别写月读自己的分区。
- provides.features 演示往月读自己的挂点加功能（契约见 book.koplugin/features/init.lua 头注释），三处共用一个开关 `bar`：
  setting（「桌面」分组里一行开关）、panel（桌面快捷面板开关）、topbar（打开时顶栏显示一句短问候）。
  值可以是表，也可以是插件内的模块名（字符串，用到时才 require）；id 由月读补成 ext.greeting.<id>，回调出错只记日志。
--]]

local _ = require("gettext")

local ID = "ext.greeting"

--- 当前问候语：按时段换，设置里可以改成自定义一句。
---@return string
local function greeting()
    local custom = require("utils.settings").getSource(ID).text
    if type(custom) == "string" and custom ~= "" then return custom end
    local hour = tonumber(os.date("%H"))
    if hour < 6 then return _("夜深了，读完这一章就睡吧") end
    if hour < 12 then return _("早上好，今天读点什么？") end
    if hour < 18 then return _("下午好，来杯茶配一章") end
    return _("晚上好，适合慢慢读")
end

--- 顶栏短问候开关（setting / panel / topbar 共用）。
---@return boolean
local function barOn()
    return require("utils.settings").getSource(ID).bar == true
end

local function setBar(on)
    local Settings = require("utils.settings")
    Settings.getSource(ID).bar = on
    Settings.saveSource(ID)
end

local features = {
    setting = {
        entries = function(desktop)
            return {
                {
                    group = "desktop",
                    order = 300,
                    row = function(iw)
                        return require("ui.themes.widgets.row").widget({
                            width = iw, icon = "wb_sunny", title = _("顶栏问候"),
                            subtitle = _("在桌面顶栏显示一句短问候"),
                            toggle = barOn(),
                            callback = function()
                                setBar(not barOn())
                                desktop:updateView()
                            end,
                        })
                    end,
                },
            }
        end,
    },
    panel = {
        actions = function()
            return {
                {
                    id = "bar", -- 月读补成 ext.greeting.bar，上线后别改（和已保存的面板布局对齐）
                    title = _("顶栏问候"),
                    icon = "wb_sunny",
                    scope = "desktop",
                    keep_open = true,
                    active = barOn,
                    run = function() setBar(not barOn()) end,
                },
            }
        end,
    },
    topbar = {
        items = function()
            return {
                {
                    id = "bar",
                    label = _("问候"),
                    icon = "wb_sunny",
                    sample = _("早上好"),
                    max_ratio = 0.25,
                    minute = true, -- 按时段换，跟着分钟心跳重读
                    read = function()
                        if not barOn() then return nil end
                        local hour = tonumber(os.date("%H"))
                        return hour < 12 and _("早上好") or hour < 18 and _("下午好") or _("晚上好")
                    end,
                },
            }
        end,
    },
}

local widget = {
    id = "hello", -- 月读补成 ext.greeting.hello
    title = _("问候"),
    icon = "wb_sunny",
    build = function(_ctx, w, h)
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local Text = require("ui.themes.widgets.text")
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, Text.line("title", greeting(), { width = w }) }
    end,
    heightRange = function()
        return { height = require("ui.themes.widgets.text").line("title", "国"):getSize().h * 2 }
    end,
    settings = function(_desktop, _id)
        local Settings = require("utils.settings")
        local conf = Settings.getSource(ID)
        require("ui.themes.widgets.input"):new{
            title = _("自定义问候语"),
            fields = { { text = conf.text or "", hint = _("留空按时段问候") } },
            callback = function(text)
                conf.text = text
                Settings.saveSource(ID)
            end,
        }:show()
    end,
}

return {
    api = 1,
    id = ID,
    provides = { source = false, home_widgets = { widget }, features = features },
}
