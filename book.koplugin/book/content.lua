--[[--
内容文件校验与 in-flight 下载合并。

@module koplugin.book.book.content
--]]

local lfs = require("libs/libkoreader-lfs")

local Content = {}

--- 最小书籍文件校验：按落盘扩展名检查可识别的格式。
---@param path string
---@param format_path string|nil 用于确定格式的最终落盘路径
---@return boolean
function Content.isValidBook(path, format_path)
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
    local ext = (format_path or path):match("%.([^.]+)$")
    ext = ext and string.lower(ext) or nil
    if ext == "txt" then
        return true
    end
    if ext == "html" or ext == "htm" or ext == "xhtml" then
        -- 非空即可；按章阅读用 HTML，不做 zip 魔数校验
        return attr.size >= 4
    end
    if ext == "mobi" or ext == "azw3" then
        -- PalmDB magic: offset 60-67 = "BOOKMOBI" (Mobi) or "TEXtREAd" (PalmDoc)
        if attr.size >= 68 then
            local f2 = io.open(path, "rb")
            if f2 then
                f2:seek("set", 60)
                local palm = f2:read(8) or ""
                f2:close()
                if palm == "BOOKMOBI" or palm == "TEXtREAd" then
                    return true
                end
            end
        end
        return false
    end
    if ext == "epub" or ext == "cbz" then
        return head == "PK\003\004" or head == "PK\005\006"
    end
    if ext == "cbr" then
        return head == "Rar!" or head == "PK\003\004"
    end
    if ext == "pdf" then
        return head == "%PDF"
    end
    return false
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
            pcall(waiters[i], ok, path, err)
        end
    end)
end

return Content
