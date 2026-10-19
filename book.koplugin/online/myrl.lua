--[[--
摸鱼日报：JSON 落 cache/online/myrl.json，图落 myrl.png，到午夜过期。
JSON 给首页农历 / 节日、单向历的干支 / 生肖 / 节气 / 新闻 / 历史；图给锁屏。

@module koplugin.book.online.myrl
--]]

local Online = require("online.base")

---@class BookOnlineMyrl : BookOnline
local Myrl = setmetatable({
    name = "myrl",
    title = "摸鱼日报",
    image_ext = "png",
    ttl = Online.untilMidnight,
}, Online)
Myrl.__index = Myrl

---@return string
function Myrl:url()
    return self.host .. "/myrl?type=json"
end

--- 锁屏日报图：竖屏尺寸。彩屏不带 ink；水墨屏 ink=1。
---@return string
function Myrl:imageUrl()
    local Device = require("device")
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    if w > h then
        w, h = h, w
    end
    -- 接口只接受 240-2560 的整数，越界直接 400
    w = math.max(240, math.min(2560, math.floor(w)))
    h = math.max(240, math.min(2560, math.floor(h)))
    local q = string.format("width=%d&height=%d", w, h)
    if not Device.screen:isColorEnabled() then
        q = q .. "&ink=1"
    end
    return self.host .. "/myrl?" .. q
end

---@param body string|nil
---@return table|nil
function Myrl:parse(body)
    local payload = Online.decode(body)
    if not payload then return nil end
    local date = type(payload.date) == "table" and payload.date or {}
    local holiday = type(payload.holiday) == "table" and payload.holiday or {}
    local quote = type(payload.quote) == "table" and payload.quote or {}
    -- 黄历字段在 almanac；旧版接口放在 date 里。
    local almanac = type(payload.almanac) == "table" and payload.almanac or date
    local daily = {
        ymd = Online.nonempty(date.ymd),
        lunar = Online.nonempty(date.lunar),
        ganzhi = Online.nonempty(almanac.ganzhi),
        animal = Online.nonempty(almanac.animal),
        term = Online.nonempty(almanac.term),
        festival = Online.nonempty(almanac.festival),
        holiday = Online.nonempty(holiday.label),
        quote_text = Online.nonempty(quote.hitokoto),
        quote_from = Online.nonempty(quote.from),
    }
    local history = {}
    for _idx, row in ipairs(type(payload.history) == "table" and payload.history or {}) do
        if type(row) == "table" then
            local year = Online.nonempty(row.year)
            local title = Online.nonempty(row.title)
            if year and title then
                history[#history + 1] = { year = year, title = title }
            end
        end
        if #history >= 8 then break end
    end
    local news = {}
    for _idx, title in ipairs(type(payload.news) == "table" and payload.news or {}) do
        title = Online.nonempty(title)
        if title then news[#news + 1] = title end
        if #news >= 8 then break end
    end
    if not (daily.lunar or daily.holiday or daily.quote_text or history[1] or news[1]) then
        return nil
    end
    daily.history = history
    daily.news = news
    return daily
end

return Myrl
