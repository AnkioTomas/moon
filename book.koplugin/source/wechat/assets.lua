--[[--
微信读书章节插图：tar 资源包 + 正文远程 img → 下载到章节工作目录并改写为相对路径。

@module koplugin.book.source.wechat.assets
--]]

local Auth = require("source.wechat.auth")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local logger = require("logger")

local Assets = {}

local WEB = "https://weread.qq.com"

---@param value string|nil
---@return string
local function trimNulls(value)
    return tostring(value or ""):gsub("%z.*$", ""):gsub("%s+$", "")
end

---@param path string|nil
---@return string
local function basename(path)
    path = tostring(path or "")
    return path:match("([^/\\]+)$") or path
end

---@param data string
---@return string mime
local function mimeFor(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return "image/png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return "image/jpeg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return "image/gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return "image/webp"
    end
    return "application/octet-stream"
end

---@param mime string
---@return string
local function extFor(mime)
    if mime == "image/png" then
        return ".png"
    elseif mime == "image/jpeg" then
        return ".jpg"
    elseif mime == "image/gif" then
        return ".gif"
    elseif mime == "image/webp" then
        return ".webp"
    end
    return ""
end

--- 递归建目录；已存在或路径为空直接返回。
---@param dir string|nil
local function ensureDir(dir)
    if not dir or dir == "" then
        return
    end
    if lfs.attributes(dir, "mode") == "directory" then
        return
    end
    local parent = dir:match("(.+)/[^/]+$")
    if parent then
        ensureDir(parent)
    end
    lfs.mkdir(dir)
end

--- 把图片写入 images/ 目录并返回相对 href（内容寻址，重复图片自动复用）。
---@param images_dir string
---@param data string
---@return string|nil
local function materializeImage(images_dir, data)
    local mime = mimeFor(data)
    if not mime:match("^image/") then
        return nil
    end
    local name = md5(data) .. extFor(mime)
    local path = images_dir .. "/" .. name
    local f = io.open(path, "rb")
    if not f then
        local w = io.open(path, "wb")
        if not w then
            return nil
        end
        w:write(data)
        w:close()
    else
        f:close()
    end
    return "images/" .. name
end

---@param src string|nil
---@return string|nil
local function remoteUrl(src)
    local url = tostring(src or ""):gsub("&amp;", "&")
    if url:match("^//") then
        url = "https:" .. url
    end
    if url:match("^https?://") then
        return url
    end
    return nil
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

--- 把 tar/远程 URL 映射后的相对图片路径写回 img src。
---@param xhtml string
---@param src_map table<string, string>
---@return string
function Assets.rewriteImageSources(xhtml, src_map)
    if type(xhtml) ~= "string" or not src_map or not next(src_map) then
        return xhtml
    end
    return xhtml:gsub("src=(['\"])(.-)%1", function(quote, src)
        local clean = tostring(src or ""):gsub("&amp;", "&")
        local bare = clean:match("^[^%?#]+") or clean
        local href = src_map[clean] or src_map[bare] or src_map[basename(bare)]
        if href then
            return "src=" .. quote .. href .. quote
        end
        return "src=" .. quote .. src .. quote
    end)
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
            local href = materializeImage(images_dir, entry.data)
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

--- 下载正文里仍指向 http(s) 的 img 并写入 images/。
---@param xhtml string
---@param referer string|nil
---@param images_dir string
---@param cb fun(html: string)
---@return table|nil
local function downloadRemoteImagesAsync(xhtml, referer, images_dir, cb)
    local urls = {}
    local seen = {}
    xhtml:gsub('src=(["\'])(.-)%1', function(_, src)
        local url = remoteUrl(src)
        if url and not seen[url] then
            seen[url] = true
            urls[#urls + 1] = url
        end
    end)
    if #urls == 0 then
        cb(xhtml)
        return nil
    end
    local url_hrefs, index = {}, 1
    local cancelled, active_job = false, nil
    --- 下载队列中的下一张远程图片；下完全部后统一把 src 改写成本地相对路径。
    --- 单张下载失败不中断，只是该 src 保持原样。
    local function nextUrl()
        if cancelled then return end
        local url = urls[index]
        index = index + 1
        if not url then
            local out = xhtml:gsub('src=(["\'])(.-)%1', function(quote, src)
                local abs = remoteUrl(src)
                local href = abs and url_hrefs[abs]
                if href then
                    return "src=" .. quote .. href .. quote
                end
                return "src=" .. quote .. src .. quote
            end)
            cb(out)
            return
        end
        active_job = downloadBinaryAsync(url, WEB .. "/", function(raw)
            if cancelled then return end
            if raw then
                local href = materializeImage(images_dir, raw)
                if href then
                    url_hrefs[url] = href
                end
            end
            nextUrl()
        end)
    end
    nextUrl()
    return {
        cancel = function()
            cancelled = true
            if active_job and active_job.cancel then active_job:cancel() end
        end,
    }
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
    ensureDir(images_dir)

    --- 交付改写后的 HTML；已取消则丢弃。
    ---@param out string
    local function finish(out)
        if not cancelled then cb(out) end
    end

    --- tar 资源包处理完后，先按包内映射改写 src，再补下仍指向 http(s) 的图片。
    ---@param src_map table<string, string>|nil 原始 src → 本地相对路径
    local function afterTar(src_map)
        if cancelled then return end
        local rewritten = Assets.rewriteImageSources(html, src_map or {})
        local job = downloadRemoteImagesAsync(rewritten, referer, images_dir, finish)
        if job then
            jobs[#jobs + 1] = job
        end
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

    return {
        cancel = function()
            cancelled = true
            for _, job in ipairs(jobs) do
                if job.cancel then job:cancel() end
            end
        end,
    }
end

return Assets
