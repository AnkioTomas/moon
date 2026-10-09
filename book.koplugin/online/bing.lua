--[[--
必应每日壁纸。元数据落 cache/online/bing.json，图落 bing.jpg，到午夜过期。
无缓存时 imageUrl 走 302；有缓存用当天的 link。

@module koplugin.book.online.bing
--]]

local Online = require("online.base")

---@class BookOnlineBing : BookOnline
local Bing = setmetatable({
    name = "bing",
    title = "必应壁纸",
    image_ext = "jpg",
    ttl = Online.untilMidnight,
}, Online)
Bing.__index = Bing

---@return string
function Bing:url()
    return self.host .. "/bing?type=json"
end

---@return string
function Bing:imageUrl()
    local link = self.data and Online.nonempty(self.data.link)
    return link or (self.host .. "/bing")
end

---@param body string|nil
---@return table|nil
function Bing:parse(body)
    local payload = Online.decode(body)
    if not payload then return nil end
    local link = Online.nonempty(payload.link)
    if not link then return nil end
    return {
        title = Online.nonempty(payload.title),
        copyright = Online.nonempty(payload.copyright),
        link = link,
    }
end

return Bing
