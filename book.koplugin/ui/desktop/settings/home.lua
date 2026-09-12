--[[-- 首页布局设置：天气地点 + 组件摘要；编辑在首页完成。
@module koplugin.book.ui.desktop.settings.home
--]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local SettingRow = require("ui.components.settingrow")
local MoonSettings = require("utils.settings")
local Registry = require("ui.desktop.home.registry")
local Widgets = require("ui.desktop.home.widgets")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsHome
local HomeSettings = {}
HomeSettings.__index = HomeSettings

---@return BookSettingsHome
function HomeSettings.new()
    return setmetatable({}, HomeSettings)
end

---@param desktop table
local function apply(desktop)
    if desktop.onEvent then desktop:onEvent("home_changed") end
    if desktop.updateView then desktop:updateView() end
end

---@param city string
---@return boolean
local function latinPlace(city)
    return city:find("[A-Za-z]") ~= nil
end

---@param height "default"|"fill"|number
---@return string
local function heightLabel(height)
    if height == "fill" then return _("占满剩余") end
    if type(height) == "number" then return T(_("高度 %1"), height) end
    return _("默认高度")
end

---@param desktop table
local function editCity(desktop)
    local home = MoonSettings.get("home")
    local testing = false
    local dialog
    local function probe()
        if testing then return end
        local city = Text.trim(dialog:getInputText())
        if city ~= "" and not latinPlace(city) then
            UIManager:show(InfoMessage:new{
                text = _("请用英文字母填写地名，例如 Shanghai"),
                timeout = 3,
            })
            return
        end
        testing = true
        local loading = InfoMessage:new{ text = _("正在测试…") }
        UIManager:show(loading)
        require("online.weather"):fetch({ city = city, ttl = 0 }, function(wx)
            testing = false
            UIManager:close(loading)
            if desktop.lifecycle and desktop.lifecycle.state == "Destroy" then return end
            if wx.temp then
                local place = wx.city or (city == "" and _("当前 IP") or city)
                local text = place .. " · " .. wx.temp .. "°"
                if wx.desc then
                    text = text .. " · " .. wx.desc
                end
                UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("测试失败：%1"), _("没有查到天气")),
                    timeout = 4,
                })
            end
        end)
    end
    dialog = InputDialog:new{
        title = _("天气地点"),
        input = tostring(home.home_weather_city or ""),
        input_hint = "Shanghai",
        description = _("留空按 IP 定位。填写请用英文字母，例如 Shanghai。"),
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("测试"),
                callback = probe,
            },
            {
                text = _("保存"),
                is_enter_default = true,
                callback = function()
                    local city = Text.trim(dialog:getInputText())
                    if city ~= "" and not latinPlace(city) then
                        UIManager:show(InfoMessage:new{
                            text = _("请用英文字母填写地名，例如 Shanghai"),
                            timeout = 3,
                        })
                        return
                    end
                    home.home_weather_city = city
                    MoonSettings.saveSection("home", home)
                    UIManager:close(dialog)
                    apply(desktop)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 关掉设置回到首页并进入编辑态。
---@param desktop table
local function openHomeEdit(desktop)
    if desktop.switchTab then
        desktop:switchTab("home")
    end
    if desktop.home and desktop.home.enterEdit then
        desktop.home:enterEdit()
    elseif desktop.onEvent then
        desktop:onEvent("home_edit")
    end
end

---@param desktop table
---@return table
function HomeSettings:sections(desktop)
    local placements = Registry.widgets()
    local pages = Widgets.pageCount(placements)

    local widget_rows = {}
    for _i, place in ipairs(placements) do
        local comp = Registry.find(place.id)
        if comp then
            local status = T(_("第 %1 页 · %2"), place.page, heightLabel(place.height))
            if place.id == "clock_weather" then
                local ClockWeather = require("ui.desktop.home.views.clock_weather")
                status = status .. " · " .. ClockWeather.orderLabel()
            end
            widget_rows[#widget_rows + 1] = function(iw)
                return SettingRow.build(iw, {
                    kind = "action",
                    chevron = false,
                    icon = comp.icon or "widgets",
                    title = comp.label,
                    status = status,
                    status_on = true,
                })
            end
        end
    end

    local city = Text.trim(MoonSettings.get("home").home_weather_city)
    local sections = {
        {
            title = _("首页数据"),
            rows = {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav",
                        icon = "location_on",
                        title = _("天气地点"),
                        subtitle = _("留空按 IP 定位。填写请用英文字母，例如 Shanghai。"),
                        status = city ~= "" and city or _("按 IP 定位"),
                        status_on = true,
                        callback = function() editCity(desktop) end,
                    })
                end,
            },
        },
        {
            title = _("首页组件"),
            rows = {
                function(iw)
                    return SettingRow.build(iw, {
                        kind = "nav",
                        icon = "edit",
                        title = _("在首页编辑"),
                        subtitle = _("长按首页也可进入编辑：增删、移动、调高度"),
                        status = T(_("%1 页 · %2 个"), pages, #placements),
                        status_on = true,
                        callback = function() openHomeEdit(desktop) end,
                    })
                end,
            },
        },
    }
    if #widget_rows > 0 then
        sections[#sections + 1] = { title = _("已放置组件"), rows = widget_rows }
    end

    -- clock_weather 左右序仍可在设置里改（不进编辑叠层）。
    local has_cw = Widgets.find(placements, "clock_weather")
    if has_cw then
        local ClockWeather = require("ui.desktop.home.views.clock_weather")
        sections[#sections + 1] = {
            title = _("时间天气"),
            rows = {
                function(iw)
                    local current = ClockWeather.order()
                    return SettingRow.build(iw, {
                        kind = "nav",
                        icon = "nest_clock_farsight_analog",
                        title = _("左右顺序"),
                        status = ClockWeather.orderLabel(),
                        status_on = true,
                        callback = function()
                            if current == ClockWeather.ORDER_WEATHER then
                                ClockWeather.saveOrder(ClockWeather.ORDER_CLOCK)
                            else
                                ClockWeather.saveOrder(ClockWeather.ORDER_WEATHER)
                            end
                            apply(desktop)
                        end,
                    })
                end,
            },
        }
    end
    return sections
end

return HomeSettings
