--[[--
ankio.net 在线接口父类。

子类填 name / title / url / parse / ttl。有图再填 image_ext。
JSON 落 cache/online/<name>.json；图落同目录 <name>.<ext>。
UI 读 current() / imagePath()。过期才 ensure() 入队（kind=online）。
fetch 是 HTTP 原语：args.ttl == 0 试查，不写盘、不下图。

@module koplugin.book.online.base
--]]

local JSON = require("json")
local Request = require("http.request")
local Image = require("utils.image")
local Text = require("utils.text")

---@class BookOnline
---@field host string
---@field name string
---@field title string|nil
---@field city string|nil
---@field image_ext string|nil
---@field ttl number|fun(self: BookOnline): number
---@field timeout number
---@field data table|nil
---@field _expire number|nil
---@field _cache_key string|nil
---@field _image_url string|nil
---@field _watchers (fun(data: table|nil, err: any))[]|nil
---@field url fun(self: BookOnline): string
---@field parse fun(self: BookOnline, body: string|nil): table|nil
local Online = {}
Online.__index = Online
Online.host = "https://api.ankio.net"
Online.timeout = 20

--- 距本地今日结束的秒数。日更用这个。
---@return number
function Online.untilMidnight()
    local now = os.time()
    local t = os.date("*t", now)
    ---@cast t osdate
    t.hour, t.min, t.sec = 0, 0, 0
    t.day = t.day + 1
    local left = os.time(t) - now
    if left < 1 then return 1 end
    return left
end

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

---@return string
local function cacheFile(self)
    return require("utils.paths").onlineCacheDir() .. "/" .. self.name .. ".json"
end

---@param rec { expire: number, data: table, key: string|nil, image_url: string|nil }
local function writeCache(self, rec)
    local ok, encoded = pcall(JSON.encode, rec)
    if not ok or type(encoded) ~= "string" then return end
    local path = cacheFile(self)
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return end
    local written = file:write(encoded)
    file:close()
    if not written or not os.rename(tmp, path) then
        os.remove(tmp)
        return
    end
    self.data = rec.data
    self._expire = rec.expire
    self._cache_key = rec.key
    self._image_url = rec.image_url
end

---@param data table
function Online:store(data)
    require("utils.paths").ensureOnlineCache()
    local ttl = self.ttl
    if type(ttl) == "function" then ttl = ttl(self) end
    -- 新 JSON 当天图还没对上；同 URL 隔日也必须重下。
    writeCache(self, {
        expire = os.time() + ttl,
        data = data,
        key = self:url(),
    })
end

---@return table|nil
function Online:load()
    local file = io.open(cacheFile(self), "rb")
    if not file then return nil end
    local raw = file:read("*a")
    file:close()
    local ok, rec = pcall(JSON.decode, raw)
    if not ok or type(rec) ~= "table" or type(rec.data) ~= "table" then return nil end
    self.data = rec.data
    self._expire = rec.expire
    self._cache_key = rec.key
    self._image_url = type(rec.image_url) == "string" and rec.image_url or nil
    return rec.data
end

--- 只给未过期的缓存。过期、没有、参数变了都是空。
---@return table|nil
function Online:current()
    if self:fresh() then
        return self.data
    end
end

---@return boolean
function Online:fresh()
    if not self.data then self:load() end
    if not self.data or type(self._expire) ~= "number" or os.time() >= self._expire then
        return false
    end
    return self._cache_key == self:url()
end

---@return string|nil
function Online:imageUrl()
    return nil
end

--- 落盘路径；没有图的接口是 nil。文件未必已经在。
---@return string|nil
function Online:imageFile()
    if not self.image_ext then return nil end
    return require("utils.paths").onlineCacheDir() .. "/" .. self.name .. "." .. self.image_ext
end

--- 本地图在才给路径。旧文件也可以，当天是否有效看 imageReady()。
---@return string|nil
function Online:imagePath()
    local path = self:imageFile()
    if Image.ok(path) then return path end
end

--- 没有图的接口永远就绪。有图则要 JSON 未过期、URL 对得上、文件是图。
---@return boolean
function Online:imageReady()
    if not self.image_ext then return true end
    return self:fresh()
        and self._image_url == self:imageUrl()
        and Image.ok(self:imageFile())
end

function Online:invalidateImage()
    local path = self:imageFile()
    if path then os.remove(path) end
    self._image_url = nil
end

---@param cb fun(ok: boolean, err: any)
---@return { cancel: fun() }|nil
local function downloadImage(self, cb)
    local path = self:imageFile()
    local url = self:imageUrl()
    if not path or not url then
        cb(false, "image")
        return
    end
    require("utils.paths").ensureOnlineCache()
    return Request.download({
        url = url,
        method = "GET",
        allow_redirects = true,
        timeout = 60,
    }, path, function(ok)
        if ok and Image.ok(path) and type(self.data) == "table"
                and type(self._expire) == "number" then
            writeCache(self, {
                expire = self._expire,
                data = self.data,
                key = self._cache_key,
                image_url = url,
            })
            cb(true)
            return
        end
        os.remove(path)
        cb(false, "image")
    end)
end

--- 锁屏用：图就绪立刻给路径；没网用旧图；否则 ensure 完再回。
---@param cb fun(path: string|nil, err: any)
---@return { cancel: fun() }|nil
function Online:ensureImage(cb)
    if self:imageReady() then
        cb(self:imagePath())
        return
    end
    if not require("ui/network/manager"):isConnected() then
        local path = self:imagePath()
        cb(path, path and nil or "offline")
        return
    end
    local function on(_data, err)
        if self:imageReady() or err then
            self:unwatch(on)
            local path = self:imagePath()
            cb(path, path and nil or (err or "image"))
        end
    end
    self:watch(on)
    self:ensure()
    return { cancel = function() self:unwatch(on) end }
end

--- args.ttl == 0 试查：不写盘、不走 http.cache。args.city 只改这次请求的 URL。
--- parse 失败带 err（HTTP 错优先，否则 "parse"），data 是未过期缓存或 nil，不合成空表。
---@param args table|nil
---@param cb fun(data: table|nil, err: any)
---@return { cancel: fun() }
function Online:fetch(args, cb)
    args = args or {}
    local saved = self.city
    if args.city ~= nil then self.city = args.city end
    local url = self:url()
    self.city = saved
    return Request.get(url, {
        timeout = self.timeout,
        allow_redirects = true,
        cache_ttl = 0,
    }, function(body, err)
        local data = self:parse(body)
        if data then
            if args.ttl ~= 0 then self:store(data) end
            cb(data)
            return
        end
        cb(self:current(), err or "parse")
    end)
end

---@param cb fun(data: table|nil, err: any)
function Online:watch(cb)
    local waiters = self._watchers
    if not waiters then
        waiters = {}
        self._watchers = waiters
    end
    for i = 1, #waiters do
        if waiters[i] == cb then return end
    end
    waiters[#waiters + 1] = cb
end

---@param cb fun(data: table|nil, err: any)
function Online:unwatch(cb)
    local waiters = self._watchers
    if not waiters then return end
    for i = #waiters, 1, -1 do
        if waiters[i] == cb then table.remove(waiters, i) end
    end
end

---@param data table|nil
---@param err any
local function notify(self, data, err)
    local waiters = self._watchers
    if not waiters then return end
    local snapshot = {}
    for i = 1, #waiters do
        snapshot[i] = waiters[i]
    end
    for i = 1, #snapshot do
        snapshot[i](data, err)
    end
end

--- JSON 或图过期才入队。未过期是空操作。url 变了（换地点）才取消在跑的同名任务。
function Online:ensure()
    if self:fresh() and self:imageReady() then return end
    local Tasks = require("workers.tasks")
    local key = "online\0" .. self.name
    local url = self:url()
    local existing = Tasks.get(key)
    if existing then
        if existing._online_url == url then return end
        existing.cancel()
    end
    require("l10n").apply()
    local title = require("gettext")(self.title or self.name)
    Tasks.enqueue{
        key = key,
        kind = "online",
        title = title,
        restartable = true,
        _online_url = url,
        retryable = function(result) return not result.ok end,
        run = function(report, done)
            report(title)
            if not require("ui/network/manager"):isConnected() then
                done({ ok = false, err = "offline" })
                return
            end
            local current
            local function stop()
                if current and current.cancel then current:cancel() end
            end
            local function afterJson(data, err)
                if self:url() ~= url then
                    done({ ok = true })
                    return
                end
                if err and not self:fresh() then
                    notify(self, data, err)
                    done({ ok = false, err = err })
                    return
                end
                if data then notify(self, data) end
                if not self.image_ext or self:imageReady() then
                    done({ ok = true })
                    return
                end
                current = downloadImage(self, function(ok, image_err)
                    if self:url() ~= url then
                        done({ ok = true })
                        return
                    end
                    if ok then
                        notify(self, self.data)
                        done({ ok = true })
                        return
                    end
                    notify(self, self.data, image_err)
                    done({ ok = false, err = image_err })
                end)
            end
            if self:fresh() then
                afterJson(self.data)
            else
                current = self:fetch(nil, afterJson)
            end
            return { cancel = stop }
        end,
    }
end

return Online
