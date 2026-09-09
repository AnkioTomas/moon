--[[--
网络图下载：一条任务一个对象。磁盘缓存 + 5 路并行。

只负责落到 md5.ext。解码不在这里。
abort / cancel 只杀这一条。

@module koplugin.book.ui.components.image.download
--]]

local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local Paths = require("utils.paths")
local Request = require("http.request")

local EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg" }
local FAILED_TTL = 5 * 60
local seq = 0
local failed = {}

---@class BookImageDownloadQueue
---@field wait table[]
---@field active number
---@field LIMIT number
local Queue = {
    wait = {},
    active = 0,
    LIMIT = 10,
}

---@class BookImageDownload
---@field url string
---@field headers table|nil
---@field cb fun(path: string|nil, err: string|nil)
---@field settled boolean
---@field cancelled boolean
---@field running boolean
---@field tmp string|nil
---@field request table|nil
local Download = {}
Download.__index = Download

--- 按文件头嗅探图片扩展名。
---@param path string
---@return string|nil
local function sniffExt(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(16) or ""
    f:close()
    if head:sub(1, 3) == "\255\216\255" then return ".jpg" end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png" end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return ".webp" end
    if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return ".gif" end
    local lower = head:lower()
    if lower:find("<svg", 1, true) or lower:find("<?xml", 1, true) then
        return ".svg"
    end
    return nil
end

---@param url string
---@return string
local function cacheBase(url)
    return Paths.imageRootDir() .. "/" .. md5(url)
end

---@param url string
---@return boolean
local function blocked(url)
    local until_t = failed[url]
    if not until_t then
        return false
    end
    if until_t <= os.time() then
        failed[url] = nil
        return false
    end
    return true
end

--- 已缓存的网络图路径；未命中返回 nil。
---@param url string
---@return string|nil
function Download.cached(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    local base = cacheBase(url)
    for _, ext in ipairs(EXTS) do
        local path = base .. ext
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and attr.size and attr.size > 0 then
            return path
        end
    end
    return nil
end

function Queue:take()
    while self.wait[1] do
        local task = table.remove(self.wait, 1)
        if not task.cancelled and not task.settled then
            return task
        end
    end
end

function Queue:release(task)
    if task.running then
        task.running = false
        self.active = self.active - 1
    end
end

function Queue:pump()
    while self.active < self.LIMIT do
        local task = self:take()
        if not task then
            return
        end
        task.running = true
        self.active = self.active + 1
        task.request = Request.download({
            url = task.url,
            method = "GET",
            headers = task.headers,
            timeout = 60,
            connect_timeout = 30,
        }, task.tmp, function(ok, err)
            task:_onHttp(ok, err)
        end)
    end
end

function Queue:publish(task)
    self.wait[#self.wait + 1] = task
    self:pump()
end

---@param url string
---@param headers table|nil
---@param cb fun(path: string|nil, err: string|nil)
---@return table
function Download.new(url, headers, cb)
    return setmetatable({
        url = url,
        headers = headers,
        cb = cb,
        settled = false,
        cancelled = false,
        running = false,
    }, Download)
end

---@param path string|nil
---@param err any
function Download:_complete(path, err)
    if not path then
        pcall(os.remove, self.tmp)
    end
    Queue:release(self)
    Queue:pump()
    if not self.cancelled then
        self.cb(path, err)
    end
end

---@param ok boolean
---@param err any
function Download:_onHttp(ok, err)
    if self.settled then
        return
    end
    self.settled = true
    if self.cancelled then
        return self:_complete()
    end
    if not ok then
        if tostring(err):find("HTTP 404", 1, true) then
            failed[self.url] = os.time() + FAILED_TTL
        end
        return self:_complete(nil, err or "download failed")
    end
    local attr = lfs.attributes(self.tmp)
    if not attr or not attr.size or attr.size < 1 then
        return self:_complete(nil, "empty")
    end
    local ext = sniffExt(self.tmp)
    if not ext then
        local path = self.url:match("^[^%?#]+") or self.url
        local from_url = path:match("%.([%w]+)$")
        if from_url then
            from_url = "." .. from_url:lower()
            for _, candidate in ipairs(EXTS) do
                if candidate == from_url then
                    ext = candidate
                    break
                end
            end
        end
    end
    if not ext then
        return self:_complete(nil, "unknown type")
    end
    local final = self.base .. ext
    if not os.rename(self.tmp, final) then
        return self:_complete(nil, "rename failed")
    end
    self:_complete(final)
end

function Download:abort()
    if self.settled or self.cancelled then
        return
    end
    self.cancelled = true
    self.settled = true
    if self.running and self.request then
        self.request:cancel()
    end
    pcall(os.remove, self.tmp)
    Queue:release(self)
    Queue:pump()
end

Download.cancel = Download.abort

function Download:start()
    local cached = Download.cached(self.url)
    if cached then
        self.settled = true
        self.cb(cached)
        return self
    end
    if blocked(self.url) then
        self.settled = true
        self.cb(nil, "HTTP 404")
        return self
    end
    Paths.ensureImageRoot()
    seq = seq + 1
    self.base = cacheBase(self.url)
    self.tmp = string.format("%s.%d.part", self.base, seq)
    Queue:publish(self)
    return self
end

return Download
