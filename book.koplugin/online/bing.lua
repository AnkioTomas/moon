--[[--
必应每日壁纸。默认 302 出图。

@module koplugin.book.online.bing
--]]

local Online = require("online.base")

---@class BookOnlineBing : BookOnline
local Bing = setmetatable({
    ttl = Online.untilMidnight,
    allow_redirects = true,
}, Online)
Bing.__index = Bing

---@param _args table|nil
---@return string
function Bing:url(_args)
    return self.host .. "/bing?type=json"
end

---@return string
function Bing:imageUrl()
    return self.host .. "/bing"
end

---@param body string|nil
---@return table|nil
function Bing:parse(body)
    local payload = Online.decode(body)
    if type(payload) ~= "table" then return nil end
    local link = Online.nonempty(payload.link)
    if not link then return nil end
    return {
        title = Online.nonempty(payload.title),
        copyright = Online.nonempty(payload.copyright),
        link = link,
    }
end

return Bing
