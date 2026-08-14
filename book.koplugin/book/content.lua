--[[--
内容文件校验与 in-flight 下载合并。

@module koplugin.book.book.content
--]]

local lfs = require("libs/libkoreader-lfs")

local Content = {}

--- 最小 EPUB/ZIP 校验：非空且魔数为 PK\\x03\\x04 或 PK\\x05\\x06
---@param path string
---@return boolean
function Content.isValidEpub(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or not attr.size or attr.size < 4 then
        return false
    end
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    local head = f:read(4) or ""
    f:close()
    -- ZIP local file header / empty archive
    if head == "PK\003\004" or head == "PK\005\006" then
        return true
    end
    -- PDF
    if head:sub(1, 4) == "%PDF" then
        return true
    end
    -- 其它支持格式：仅非空即可（cbz 也是 zip）
    local ext = path:match("%.([^.]+)$")
    if ext then
        ext = string.lower(ext)
        if ext == "txt" or ext == "mobi" or ext == "azw3" then
            return attr.size > 0
        end
        if ext == "cbz" or ext == "cbr" or ext == "epub" then
            return head:sub(1, 2) == "PK"
        end
        if ext == "pdf" then
            return head:sub(1, 4) == "%PDF"
        end
    end
    return head:sub(1, 2) == "PK" or head:sub(1, 4) == "%PDF"
end

---@type table<string, { waiters: function[], done: boolean, ok: boolean|nil, path: string|nil, err: any }>
local inflight = {}

--- 同一 key 合并为一个 in-flight job；其余订阅结果。
---@param key string
---@param start_fn fun(finish: fun(ok: boolean, path: string|nil, err: any))
---@param cb fun(ok: boolean, path: string|nil, err: any)
function Content.sharedJob(key, start_fn, cb)
    if type(key) ~= "string" or key == "" or type(cb) ~= "function" then
        return
    end
    local job = inflight[key]
    if job then
        if job.done then
            cb(job.ok, job.path, job.err)
            return
        end
        job.waiters[#job.waiters + 1] = cb
        return
    end
    job = { waiters = { cb }, done = false }
    inflight[key] = job
    start_fn(function(ok, path, err)
        job.done = true
        job.ok = ok
        job.path = path
        job.err = err
        local waiters = job.waiters
        inflight[key] = nil
        for i = 1, #waiters do
            waiters[i](ok, path, err)
        end
    end)
end

return Content
