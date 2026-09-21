--[[--
微信读书章节插图：tar 资源包解出后，远程 img 走 source.assets 落地。

@module koplugin.book.source.wechat.assets
--]]

local Auth = require("source.wechat.auth")
local Shared = require("source.assets")
local Paths = require("utils.paths")
local logger = require("utils.log")

local Assets = {}

local WEB = "https://weread.qq.com"

Assets.rewriteImageSources = Shared.rewriteImageSources

---@param value string|nil
---@return string
local function trimNulls(value)
    return (tostring(value or ""):gsub("%z.*$", ""):gsub("%s+$", ""))
end

---@param path string|nil
---@return string
local function basename(path)
    path = tostring(path or "")
    return path:match("([^/\\]+)$") or path
end

---@param data string
---@return table[]
local function tarEntries(data)
    local entries = {}
    local offset = 1
    while offset + 511 <= #data do
        local header = data:sub(offset, offset + 511)
        if header:match("^%z+$") then
            break
        end
        local name = trimNulls(header:sub(1, 100))
        local size_text = trimNulls(header:sub(125, 136)):gsub("%s", "")
        local size = tonumber(size_text, 8) or 0
        local typeflag = header:sub(157, 157)
        local body_start = offset + 512
        local body_end = body_start + size - 1
        if name ~= "" and (typeflag == "0" or typeflag == "" or typeflag == "\0") and size > 0 then
            entries[#entries + 1] = {
                name = name,
                data = data:sub(body_start, body_end),
            }
        end
        offset = body_start + math.ceil(size / 512) * 512
    end
    return entries
end

---@param tar string
---@return string
local function absTarUrl(tar)
    tar = tostring(tar or "")
    if tar:match("^//") then
        return "https:" .. tar
    end
    if tar:match("^/") then
        return WEB .. tar
    end
    return tar
end

---@param url string
---@param referer string|nil
---@param cb fun(data: string|nil, err: any)
---@return table|nil
local function downloadBinaryAsync(url, referer, cb)
    return Auth.webGetAsync(url, {
        accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        headers = {
            ["Referer"] = referer or (WEB .. "/"),
        },
        block_timeout = 90,
        allow_redirects = true,
        -- CDN 403 不是会话失效，禁止走 renewal 误判。
        skip_auth_retry = true,
    }, function(raw, err)
        if not raw or raw == "" then
            logger.dbg("wechat image download failed", url, err)
            cb(nil, err)
        else
            cb(raw)
        end
    end)
end

--- 下载章节 tar 包，提取图片写入 images/ 并返回 src 映射。
---@param tar string
---@param referer string|nil
---@param images_dir string
---@param cb fun(src_map: table|nil, err: any)
---@return table|nil
local function downloadTarAsync(tar, referer, images_dir, cb)
    local url = absTarUrl(tar)
    if url == "" then
        cb({})
        return nil
    end
    return downloadBinaryAsync(url, referer, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local src_map = {}
        for _, entry in ipairs(tarEntries(raw)) do
            local href = Shared.materializeImage(images_dir, entry.data)
            if href then
                local name = basename(entry.name)
                src_map[name] = href
                local stem = name:gsub("%.[^%.]+$", "")
                if stem ~= "" and stem ~= name then
                    src_map[stem] = href
                end
            end
        end
        cb(src_map)
    end)
end

--- 把章节 HTML 内图片下载到章节工作目录并改写为相对路径。
---@param book_id string
---@param chapter BookChapter
---@param html string
---@param referer string|nil
---@param cb fun(html: string)
---@return { cancel: fun() }
function Assets.localizeAsync(book_id, chapter, html, referer, cb)
    local cancelled = false
    local jobs = {}
    local images_dir = Paths.bookWorkDir(book_id, "wechat") .. "/images"

    --- 交付改写后的 HTML；已取消则丢弃。
    ---@param out string
    local function finish(out)
        if not cancelled then cb(out) end
    end

    --- tar 资源包处理完后，先按包内映射改写 src，再补下仍指向 http(s) 的图片。
    ---@param src_map table<string, string>|nil 原始 src → 本地相对路径
    local function afterTar(src_map)
        if cancelled then return end
        local rewritten = Shared.rewriteImageSources(html, src_map or {})
        local job = Shared.localizeAsync(rewritten, images_dir, function(url, done)
            return downloadBinaryAsync(url, WEB .. "/", done)
        end, finish)
        jobs[#jobs + 1] = job
    end

    if type(chapter.tar) == "string" and chapter.tar ~= "" then
        local job = downloadTarAsync(chapter.tar, referer, images_dir, function(src_map, err)
            if cancelled then return end
            if not src_map then
                logger.dbg("wechat tar assets failed", book_id, chapter.uid, err)
                src_map = {}
            end
            afterTar(src_map)
        end)
        if job then jobs[#jobs + 1] = job end
    else
        afterTar({})
    end

    return { cancel = function()
            cancelled = true
            for _, job in ipairs(jobs) do
                if job.cancel then job:cancel() end
            end
        end }
end

return Assets
