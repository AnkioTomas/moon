--[[--
章节远程插图：下载到书籍工作目录并改写为相对路径。

源注入 download(url, cb)；这里不碰 HTTP、不碰鉴权。
微信 tar 包仍由 source.wechat.assets 解包，解完后走同一条远程落地。

@module koplugin.book.source.assets
--]]

local md5 = require("ffi/sha2").md5
local Paths = require("utils.paths")
local Text = require("utils.text")

local Assets = {}

--- 按文件头识别图片扩展名；不是已知图片返回 nil。
---@param data string
---@return string|nil
local function imageExt(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return ".jpg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp"
    end
    return nil
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

--- 把图片写入 images/ 并返回相对 href（内容寻址，重复图片自动复用）。
---@param images_dir string
---@param data string
---@return string|nil
function Assets.materializeImage(images_dir, data)
    local ext = imageExt(data)
    if not ext then
        return nil
    end
    Paths.ensureDir(images_dir)
    local name = md5(data) .. ext
    local path = images_dir .. "/" .. name
    local f = io.open(path, "rb")
    if f then
        f:close()
        return "images/" .. name
    end
    -- 内容寻址：目标名存在即视为完整，所以只能整份写完再 rename 到位。
    local tmp = path .. ".part"
    local w = io.open(tmp, "wb")
    if not w then
        return nil
    end
    local wrote = w:write(data)
    local closed = w:close()
    if not wrote or not closed or not os.rename(tmp, path) then
        os.remove(tmp)
        return nil
    end
    return "images/" .. name
end

--- 按 src 映射改写 img；命中时同一标签上的 href 一并改掉。
---@param xhtml string
---@param src_map table<string, string>
---@return string
function Assets.rewriteImageSources(xhtml, src_map)
    if type(xhtml) ~= "string" or not src_map or not next(src_map) then
        return xhtml
    end
    return (xhtml:gsub("<img%s+[^>]*>", function(tag)
        local _, src = tag:match("src=(['\"])(.-)%1")
        if not src then
            return tag
        end
        local clean = src:gsub("&amp;", "&")
        local bare = clean:match("^[^%?#]+") or clean
        local href = src_map[clean] or src_map[bare] or src_map[Text.basename(bare)]
        if not href then
            return tag
        end
        tag = tag:gsub("src=(['\"])(.-)%1", function(quote)
            return "src=" .. quote .. href .. quote
        end, 1)
        if tag:find("href=", 1, true) then
            tag = tag:gsub("href=(['\"])(.-)%1", function(quote)
                return "href=" .. quote .. href .. quote
            end, 1)
        end
        return tag
    end))
end

--- 下载正文里的远程 img，写入 images_dir，改写成相对路径。
---@param html string
---@param images_dir string
---@param download fun(url: string, cb: fun(data: string|nil, err: any)): { cancel: fun() }|nil
---@param cb fun(html: string)
---@return { cancel: fun() }
function Assets.localizeAsync(html, images_dir, download, cb)
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

    Paths.ensureDir(images_dir)

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
        active_job = download(url, function(raw)
            if cancelled then return end
            if raw then
                local href = Assets.materializeImage(images_dir, raw)
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
