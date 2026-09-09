--[[--
ankio.net 在线接口父类。

子类填 url / parse；要落盘的再覆盖 store / load。
TTL 原样交给 Request.get 的 cache_ttl，这里不判断新鲜度。

@module koplugin.book.online.base
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")

---@class BookOnline
---@field host string
---@field ttl number|fun(self: BookOnline): number
---@field timeout number
---@field allow_redirects boolean|nil
local Online = {}
Online.__index = Online
Online.host = "https://api.ankio.net"
Online.ttl = 0
Online.timeout = 20

--- 距本地今日结束的秒数。日更数据用这个，不要写死 24*3600。
---@return number
function Online.untilMidnight()
    local now = os.time()
    local t = os.date("*t", now)
    t.hour, t.min, t.sec = 0, 0, 0
    t.day = t.day + 1
    local left = os.time(t) - now
    if left < 1 then return 1 end
    return left
end

---@param value any
---@return string|nil
function Online.nonempty(value)
    if type(value) ~= "string" then return nil end
    value = Text.trim(value)
    if value == "" then return nil end
    return value
end

--- JSON 解码；有 data 表就剥掉外壳。
---@param body string|nil
---@return table|nil
function Online.decode(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then return nil end
    if type(data.data) == "table" then return data.data end
    return data
end

--- 水墨屏才带 ink。彩屏（含已开彩色渲染）不要。认不出设备时按水墨。
---@return boolean
function Online.useInk()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" then return true end
    local screen = Device.screen
    if screen and type(screen.isColorEnabled) == "function" then
        return not screen:isColorEnabled()
    end
    if type(Device.hasColorScreen) == "function" then
        return not Device:hasColorScreen()
    end
    return true
end

---@param _args table|nil
---@return string
function Online:url(_args)
    error("online: url() not implemented")
end

---@param body string|nil
---@return table|nil
function Online:parse(body)
    return Online.decode(body)
end

---@param _data table
function Online:store(_data) end

---@return table|nil
function Online:load()
    return nil
end

--- args.ttl 覆盖默认；0 表示不走 http.cache。ttl 可以是函数，请求时再算。
---@param args table|nil
---@param cb fun(data: table, err: any)
---@return { cancel: fun() }
function Online:fetch(args, cb)
    args = args or {}
    local ttl = args.ttl
    if ttl == nil then ttl = self.ttl end
    if type(ttl) == "function" then ttl = ttl(self) end
    return Request.get(self:url(args), {
        timeout = self.timeout,
        allow_redirects = self.allow_redirects,
        cache_ttl = ttl,
    }, function(body, err)
        local data = self:parse(body)
        if data then
            self:store(data)
            cb(data)
            return
        end
        cb(self:load() or {}, err)
    end)
end

return Online
