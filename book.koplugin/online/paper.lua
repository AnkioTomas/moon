--[[--
今日报纸：JSON 落 cache/online/paper.json，图落 paper.png，到午夜过期。
图给锁屏；城市沿用首页天气的设置，换城市 url 变了自动重拉。

@module koplugin.book.online.paper
--]]

local Online = require("online.base")
local Text = require("utils.text")

---@class BookOnlinePaper : BookOnline
local Paper = setmetatable({
    name = "paper",
    title = "今日报纸",
    image_ext = "png",
    ttl = Online.untilMidnight,
}, Online)
Paper.__index = Paper

---@return string
function Paper:city()
    local home = require("utils.settings").get("desktop.pages.home")
    return Text.urlEncode(Text.trim(home.home_weather_city or ""))
end

---@return string
function Paper:url()
    return self.host .. "/paper?type=json&city=" .. self:city()
end

--- 竖屏尺寸；接口只接受 240-2560 的整数。彩屏不带 ink，水墨屏 ink=1。
---@return string
function Paper:imageUrl()
    local Device = require("device")
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    if w > h then
        w, h = h, w
    end
    w = math.max(240, math.min(2560, math.floor(w)))
    h = math.max(240, math.min(2560, math.floor(h)))
    local q = string.format("width=%d&height=%d&city=%s", w, h, self:city())
    if not Device.screen:isColorEnabled() then
        q = q .. "&ink=1"
    end
    return self.host .. "/paper?" .. q
end

---@param body string|nil
---@return table|nil
function Paper:parse(body)
    local payload = Online.decode(body)
    if not payload then return nil end
    local title, date = Online.nonempty(payload.title), Online.nonempty(payload.date)
    if not (title or date) then return nil end
    return { title = title, date = date }
end

return Paper
