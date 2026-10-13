--[[--
主体：天气。布局跟时钟同构：居中大温度 + 下方两行辅文；读 online.weather，成功才刷。
天气预报（weather_forecast.lua）继承本模块，只打开 forecast，底部多一行未来预报。

@module koplugin.book.desktop.pages.home.weather
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Clock = require("desktop.pages.home.clock")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MoonSettings = require("utils.settings")
local OnlineWeather = require("online.weather")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Image = require("ui.themes.widgets.image")
local ThemeText = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")
local T = require("ffi/util").template

local INTERVAL = 3600
local PICTURE = 36
--- 空态占位：多云图，比 unknown 看着不像出错。
local EMPTY_ICON = "cloud"
--- 预报档数、每格图标边长与格宽上限（逻辑像素）。
local FORECAST_N = 4
local FORECAST_ICON = 24
local FORECAST_CELL = 84

---@class BookHomeWeather : BookHomeComponent
---@field wx BookWeather|nil
---@field picture table|nil
---@field hero table|nil
---@field temp table|nil
---@field detail table|nil
---@field extra table|nil
---@field column table|nil
---@field forecast boolean 底部是否带未来预报行（天气预报组件为真）
---@field forecast_key string|nil 当前预报行内容签名
---@field _tick fun()|nil
local M = {
    id = "weather",
    label = _("天气预报"),
    icon = "partly_cloudy_day",
    forecast = false,
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

--- 预报行高度：时间 + 图标 + 温度。
---@return number
local function forecastHeight()
    local xs = Theme.px(Theme.current().space.xs)
    return ThemeText.line("caption", "0"):getSize().h * 2 + Theme.px(FORECAST_ICON) + xs * 2
end

--- 返回天气内容高度；与时钟同构。带预报的子类再加一行（没有预报数据也留着，高度不随数据跳）。
---@return BookHomeHeightSpec
function M:heightRange()
    local h = Clock.contentHeight()
    if self.forecast then h = h + Theme.px(Theme.current().space.sm) + forecastHeight() end
    return { height = h }
end

--- 预报格的时间文案：逐小时直接用 HH:MM；逐日按距今天数写明天 / 后天，再远写月-日。
---@param item BookWeatherForecast
---@return string
local function forecastLabel(item)
    if item.kind == "hour" then return item.label end
    local y, m, d = item.label:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return item.label end
    local today = os.date("*t")
    local diff = math.floor((os.time{ year = y, month = m, day = d, hour = 12 }
        - os.time{ year = today.year, month = today.month, day = today.day, hour = 12 }) / 86400 + 0.5)
    if diff == 1 then return _("明天") end
    if diff == 2 then return _("后天") end
    return item.label:sub(6)
end

---@param item BookWeatherForecast
---@return string
local function forecastTemp(item)
    if item.kind == "hour" then return item.temp and item.temp .. "°" or "" end
    if item.low and item.high then return item.low .. "–" .. item.high .. "°" end
    return ""
end

--- 预报行内容签名，判断要不要重建。
---@param items BookWeatherForecast[]
---@return string
local function forecastKey(items)
    local key = {}
    for i, item in ipairs(items) do key[i] = item.label .. forecastTemp(item) .. item.image end
    return table.concat(key, "\31")
end

--- 预报行：最多 FORECAST_N 格居中排开；没有预报返回 nil。
---@param self BookHomeWeather
---@param w number 可用宽度
---@return table|nil
local function forecastRow(self, w)
    local items = OnlineWeather.upcoming(self.wx, FORECAST_N)
    self.forecast_key = forecastKey(items)
    if #items == 0 then return nil end
    local t = Theme.current()
    local cell_w = math.min(Theme.px(FORECAST_CELL), math.floor(w / FORECAST_N))
    local icon = Theme.px(FORECAST_ICON)
    local xs = VerticalSpan:new{ width = Theme.px(t.space.xs) }
    local row = HorizontalGroup:new{ align = "top" }
    for _idx, item in ipairs(items) do
        row[#row + 1] = CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = forecastHeight() },
            VerticalGroup:new{
                align = "center",
                ThemeText.line("caption", forecastLabel(item), { width = cell_w, color = t.color.muted }),
                xs,
                Image.widget{ src = item.image, width = icon, height = icon, style = {} },
                xs,
                ThemeText.line("caption", forecastTemp(item), { width = cell_w }),
            },
        }
    end
    return row
end

--- 天气里显示的地名：用户填了地点就用填的；留空按 IP 定位时才用接口的观测点名
--（接口会把填的城市匹配到附近不相干的小地方，例如 Nantong → Dexing）。
---@param wx BookWeather
---@return string|nil
local function placeName(wx)
    local city = Text.trim(OnlineWeather.city or "")
    if city ~= "" then return city end
    return wx.city ~= "" and wx.city or nil
end

--- 辅文第一行：天气 · 地点 · 温差。
---@param wx BookWeather 天气接口返回的数据
---@return string
local function summary(wx)
    local parts = {}
    if wx.desc and wx.desc ~= "" then parts[#parts + 1] = wx.desc end
    parts[#parts + 1] = placeName(wx)
    if wx.low and wx.high then
        parts[#parts + 1] = wx.low .. "–" .. wx.high .. "°"
    end
    return #parts > 0 and table.concat(parts, " · ") or "--"
end

--- 辅文第二行：体感 / 湿度 / 风向风速；都没有就日出日落。
---@param wx BookWeather 天气接口返回的数据
---@return string
local function metrics(wx)
    local parts = {}
    if wx.feels then
        parts[#parts + 1] = T(_("体感 %1°"), wx.feels)
    end
    if wx.humidity then
        parts[#parts + 1] = T(_("湿度 %1%"), wx.humidity)
    end
    if wx.wind and wx.wind_kmph then
        parts[#parts + 1] = T(_("%1风 %2km/h"), wx.wind, wx.wind_kmph)
    elseif wx.wind then
        parts[#parts + 1] = wx.wind .. _("风")
    elseif wx.wind_kmph then
        parts[#parts + 1] = wx.wind_kmph .. "km/h"
    end
    if #parts == 0 and wx.sunrise and wx.sunset then
        parts[1] = T(_("日出 %1"), wx.sunrise)
        parts[2] = T(_("日落 %1"), wx.sunset)
    end
    return #parts > 0 and table.concat(parts, " · ") or "--"
end

--- 大温度 + 两行辅文。空态只留图标和一行提示，不拿 hero 字号画占位符。
---@param wx BookWeather|nil 天气接口返回的数据
---@return string
---@return string
---@return string
local function texts(wx)
    wx = wx or {}
    if not wx.temp then
        return "", _("暂无天气"), ""
    end
    return wx.temp .. "°", summary(wx), metrics(wx)
end

--- 有天气用接口图（或按 icon 键回退）；空态用多云占位。
---@param wx BookWeather|nil 天气接口返回的数据
---@return string
local function imageSrc(wx)
    if wx and wx.temp then
        if type(wx.image) == "string" and wx.image ~= "" then
            return wx.image
        end
        return OnlineWeather.iconUrl(wx.icon or "unknown")
    end
    return OnlineWeather.iconUrl(EMPTY_ICON)
end

--- 取消当前天气图标的在飞请求并清除图标引用。
---@param self BookHomeWeather 当前视图或布局实例
local function dropPicture(self)
    if self.picture then self.picture[1]:cancel() end
    self.picture = nil
end

--- 主行左侧图标；同一 URL 不换框。
---@param self BookHomeWeather 当前视图或布局实例
---@return table
local function mark(self)
    local src = imageSrc(self.wx)
    if self.picture and self.picture.src == src then
        return self.picture
    end
    dropPicture(self)
    local size = Theme.px(PICTURE)
    self.picture = Image.widget{ src = src, width = size, height = size, style = {} }
    self.picture.src = src
    return self.picture
end

--- 替换主天气行的图标并复用温度文字；释放旧图标后重置行布局缓存。
---@param self BookHomeWeather 当前视图或布局实例
---@return table
local function putHero(self)
    local icon = mark(self)
    local hero = self.hero
    if not hero then
        hero = HorizontalGroup:new{ align = "center" }
        self.hero = hero
    end
    local previous = hero[1]
    hero[1] = icon
    if self.temp.text == "" then
        hero[2], hero[3] = nil, nil
    else
        hero[2], hero[3] = hero[2] or HorizontalSpan:new{ width = Theme.px(Theme.current().space.sm) }, self.temp
    end
    if previous and previous ~= icon then previous:free() end
    hero:resetLayout()
    return hero
end

--- 取消本实例保存的定时回调并清除句柄。
---@param self BookHomeWeather 当前视图或布局实例
local function stopTick(self)
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = nil
end

--- 构建主天气图标、温度和辅助信息行，旧图标请求先取消。
---@return table
function M:createWidget()
    dropPicture(self)
    self.hero = nil
    local temp, detail, extra = texts(self.wx)
    self.temp = ThemeText.line("hero", temp)
    return Clock.stack(self, putHero(self), detail, extra, self.forecast and forecastRow(self, self.opts.width) or nil)
end

--- 预报档位变了（新数据或时间滚过一档）整块重建；否则把最新天气写入已有文字和图标行，都未变时不刷新。
function M:paint()
    if not self.temp then return end
    if self.forecast and forecastKey(OnlineWeather.upcoming(self.wx, FORECAST_N)) ~= self.forecast_key then
        self:refresh()
        return
    end
    local temp, detail, extra = texts(self.wx)
    if self.temp.text == temp and self.detail.text == detail and self.extra.text == extra
        and self.picture and self.picture.src == imageSrc(self.wx) then
        return
    end
    self.temp:setText(temp)
    self.detail:setText(detail)
    self.extra:setText(extra)
    putHero(self)
    self.column:resetLayout()
    self:dirty()
end

--- 按当前设置写地点后 ensure；未过期不拉网，换地点才拆掉重拉。
function M:bindCity()
    OnlineWeather.city = Text.trim(MoonSettings.get("desktop.pages.home").home_weather_city)
end

--- 失败或缺温度保留旧天气；数据变化由 watch 回调重绘。
function M:pull()
    self:bindCity()
    OnlineWeather:ensure()
end

--- 取消旧定时器并安排下一次天气拉取，只在活跃时续订。
function M:scheduleHourly()
    stopTick(self)
    if not self.active then return end
    self._tick = require("ui.guard").wrap("home weather", function()
        if not self.active then return end
        self:paint()
        self:pull()
        self:scheduleHourly()
    end)
    UIManager:scheduleIn(INTERVAL, self._tick)
end

--- 首页刷新（改了地点）或换源后按当前地点重拉天气。
---@param event string
function M:onEvent(event)
    if event == "home_refresh" or event == "source_changed" then
        self:pull()
    end
end

--- 先画已有结果，再订阅；过期才入队。整点再 ensure 一次。
function M:onActivate()
    self:bindCity()
    self.wx = OnlineWeather:current()
    self:paint()
    self._on_wx = function(data, err)
        if err or not (data and data.temp) or data == self.wx then return end
        self.wx = data
        self:paint()
    end
    OnlineWeather:watch(self._on_wx)
    OnlineWeather:ensure()
    self:scheduleHourly()
end

--- 取消整点定时和图标请求；不取消 online 任务。
function M:onDeactivate()
    OnlineWeather:unwatch(self._on_wx)
    self._on_wx = nil
    stopTick(self)
    dropPicture(self)
end

--- 清除天气图标行和文字控件引用。
function M:onDestroy()
    self.hero = nil
    self.temp = nil
    self.detail = nil
    self.extra = nil
    self.column = nil
end

--- 地名必须是英文字母（接口不吃中文）；不合规时提示并返回 true。
---@param city string
---@return boolean
local function rejectPlace(city)
    if city == "" or city:find("[A-Za-z]") then return false end
    Toast:new{ text = _("请用英文字母填写地名，例如 Shanghai"), timeout = 3 }:show()
    return true
end

--- 试查一次天气并提示结果，不保存。
---@param city string
---@param desktop BookDesktop
---@param done fun() 查完（无论成败）
local function probe(city, desktop, done)
    local loading = require("ui.themes.widgets.progress_dialog"):new{
        title = city, text = _("正在测试…"), dismissable = false,
    }
    loading:show()
    OnlineWeather:fetch({ city = city, ttl = 0 }, function(wx)
        done()
        loading:close()
        if desktop.closed then return end
        local text = T(_("测试失败：%1"), _("没有查到天气"))
        if wx and wx.temp then
            text = (city ~= "" and city or wx.city or _("当前 IP")) .. " · " .. wx.temp .. "°"
            if wx.desc then text = text .. " · " .. wx.desc end
        end
        Toast:new{ text = text, timeout = 4 }:show()
    end)
end

--- 编辑态设置：天气地点输入框。地名不合规时提示后带着原输入重开。
---@param desktop BookDesktop
---@param text string|nil 重开时保留的输入
function M:showSettings(desktop, text)
    local home = MoonSettings.get("desktop.pages.home")
    local testing = false
    require("ui.themes.widgets.input"):new{
        title = _("天气地点"),
        fields = { {
            label = _("留空按 IP 定位。填写请用英文字母，例如 Shanghai。"),
            text = text or home.home_weather_city or "",
            hint = "Shanghai",
        } },
        ok_text = _("保存"),
        actions = { { text = _("测试"), callback = function(raw)
            local city = Text.trim(raw)
            if testing or rejectPlace(city) then return end
            testing = true
            probe(city, desktop, function() testing = false end)
        end } },
        callback = function(raw)
            local city = Text.trim(raw)
            if rejectPlace(city) then
                self:showSettings(desktop, raw)
                return
            end
            home.home_weather_city = city
            MoonSettings.save("desktop.pages.home", home)
            desktop:onEvent("home_refresh")
        end,
    }:show()
end

return M
