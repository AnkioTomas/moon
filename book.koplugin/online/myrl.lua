--[[--
摸鱼日报 JSON：农历 / 节日 / 新闻 / 历史 / 一言。

@module koplugin.book.online.myrl
--]]

local Online = require("online.base")

---@class BookOnlineMyrl : BookOnline
local Myrl = setmetatable({
    ttl = Online.untilMidnight,
}, Online)
Myrl.__index = Myrl

---@param _args table|nil
---@return string
function Myrl:url(_args)
    return self.host .. "/myrl?type=json"
end

--- 锁屏日报图。彩屏不带 ink；水墨屏 ink=1。
---@param w number
---@param h number
---@return string
function Myrl:imageUrl(w, h)
    local q = string.format("width=%d&height=%d", tonumber(w) or 0, tonumber(h) or 0)
    if Online.useInk() then
        q = q .. "&ink=1"
    end
    return self.host .. "/myrl?" .. q
end

---@param body string|nil
---@return table|nil
function Myrl:parse(body)
    local payload = Online.decode(body)
    if type(payload) ~= "table" then return nil end
    local date = type(payload.date) == "table" and payload.date or {}
    local holiday = type(payload.holiday) == "table" and payload.holiday or {}
    local quote = type(payload.quote) == "table" and payload.quote or {}
    local daily = {
        lunar = Online.nonempty(date.lunar),
        holiday = Online.nonempty(holiday.label),
        quote_text = Online.nonempty(quote.hitokoto),
        quote_from = Online.nonempty(quote.from),
    }
    local history = {}
    for _, row in ipairs(type(payload.history) == "table" and payload.history or {}) do
        if type(row) == "table" then
            local year = Online.nonempty(row.year)
            local title = Online.nonempty(row.title)
            if year and title then
                history[#history + 1] = { year = year, title = title }
            end
        end
        if #history >= 8 then break end
    end
    daily.history = history
    local news = {}
    for _, title in ipairs(type(payload.news) == "table" and payload.news or {}) do
        title = Online.nonempty(title)
        if title then news[#news + 1] = title end
        if #news >= 8 then break end
    end
    daily.news = news
    return daily
end

return Myrl
