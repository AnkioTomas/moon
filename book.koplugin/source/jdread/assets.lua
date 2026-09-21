--[[--
京东读书章节插图：正文远程 img → 下载到书籍工作目录并改写为相对路径。

新阅读器 EPUB 正文里的 src 已是 https://img30.360buyimg.com/... 绝对地址，
KOReader 不拉远程图；不落地的话章节落盘后图就是空的。

@module koplugin.book.source.jdread.assets
--]]

local Request = require("http.request")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local logger = require("utils.log")

local Assets = {}

local REFERER = "https://e.m.jd.com/"

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

--- 把已下载的相对路径写回 img src，并清掉 EPUB 遗留的 href。
---@param xhtml string
---@param src_map table<string, string>
---@return string
function Assets.rewriteImageSources(xhtml, src_map)
    if type(xhtml) ~= "string" or not src_map or not next(src_map) then
        return xhtml
    end
    return (xhtml:gsub("<img%s+[^>]*>", function(tag)
        local _, src = tag:match("src=(['\"])(.-)%1")
        local local_href = src and src_map[remoteUrl(src) or ""]
        if not local_href then
            return tag
        end
        tag = tag:gsub("src=(['\"])(.-)%1", function(quote)
            return "src=" .. quote .. local_href .. quote
        end, 1)
        if tag:find("href=", 1, true) then
            tag = tag:gsub("href=(['\"])(.-)%1", function(quote)
                return "href=" .. quote .. local_href .. quote
            end, 1)
        end
        return tag
    end))
end

---@param url string
---@param cb fun(data: string|nil, err: any)
---@return table|nil
local function downloadBinaryAsync(url, cb)
    return Request.get(url, {
        accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        headers = {
            ["Referer"] = REFERER,
        },
        block_timeout = 90,
        allow_redirects = true,
    }, function(raw, err)
        if not raw or raw == "" then
            logger.dbg("jdread image download failed", url, err)
            cb(nil, err)
        else
            cb(raw)
        end
    end)
end

--- 把章节 HTML 内远程图片下载到书籍工作目录并改写为相对路径。
---@param book_id string
---@param html string
---@param cb fun(html: string)
---@return { cancel: fun() }
function Assets.localizeAsync(book_id, html, cb)
    html = tostring(html or "")
    local urls, seen = {}, {}
    html:gsub('src=(["\'])(.-)%1', function(_, src)
        local url = remoteUrl(src)
        if url and not seen[url] then
            seen[url] = true
            urls[#urls + 1] = url
        end
    end)
    if #urls == 0 then
        cb(html)
        return { cancel = function() end }
    end

    local images_dir = Paths.bookWorkDir(book_id, "jdread") .. "/images"
    ensureDir(images_dir)

    local url_hrefs, index = {}, 1
    local cancelled, active_job = false, nil
    local function nextUrl()
        if cancelled then return end
        local url = urls[index]
        index = index + 1
        if not url then
            cb(Assets.rewriteImageSources(html, url_hrefs))
            return
        end
        active_job = downloadBinaryAsync(url, function(raw)
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
    return { cancel = function()
            cancelled = true
            if active_job and active_job.cancel then active_job.cancel() end
        end }
end

return Assets
