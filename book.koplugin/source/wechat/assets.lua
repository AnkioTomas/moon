--[[--
微信读书章节资源本地化：插图（tar 资源包 + 远程 img）、脚注图标、整书样式表。

只改资源引用（img src、link href），正文其余字节不动。

@module koplugin.book.source.wechat.assets
--]]

local Auth = require("source.wechat.auth")
local Shared = require("source.assets")
local Paths = require("utils.paths")
local Text = require("utils.text")
local logger = require("utils.log")

local Assets = {}

local WEB = "https://weread.qq.com"
local DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
-- 原书脚注图只在 EPUB 里，服务端不给；网页端换成「注」图标，这里用插件自带的同一张。
local FOOTNOTE_SRC = "../Images/note.png"
local STYLE_NAME = "stylesheets.css"

--- 脚注图标落到 images/，返回相对 href。
---@param images_dir string
---@return string|nil
local function footnoteHref(images_dir)
    local f = assert(io.open(DIR .. "/note.png", "rb"))
    local data = f:read("*a")
    f:close()
    return Shared.materializeImage(images_dir, data)
end

--- 整份写完再 rename，避免半截文件被当成已缓存。
---@param path string
---@param data string
---@return boolean
local function writeFile(path, data)
    local tmp = path .. ".part"
    local w = io.open(tmp, "wb")
    if not w then return false end
    local wrote = w:write(data)
    local closed = w:close()
    if not wrote or not closed or not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    return true
end

--- 相对路径的 css link 一律指向工作目录里的整书样式表（e_2 st=1 回的就是全部样式）。
---@param html string
---@return string rewritten
---@return integer count
local function rewriteStyleLinks(html)
    local count = 0
    local out = html:gsub("(<link%s[^>]-href=)([\"'])([^\"']-%.css)%2", function(prefix, quote, href)
        if href:match("^%a[%w+.-]*:") or href:match("^//") then return nil end
        count = count + 1
        return prefix .. quote .. STYLE_NAME .. quote
    end)
    return out, count
end

--- 样式表每本书只拉一次；拉不到就保留原 link，下一章再试。
---@param work_dir string
---@param html string
---@param fetch_style fun(done: fun(css: string|nil)): { cancel: fun() }|nil
---@param cb fun(html: string)
---@return { cancel: fun() }|nil
local function localizeStyleAsync(work_dir, html, fetch_style, cb)
    local rewritten, count = rewriteStyleLinks(html)
    if count == 0 then
        cb(html)
        return nil
    end
    local path = work_dir .. "/" .. STYLE_NAME
    local f = io.open(path, "rb")
    if f then
        f:close()
        cb(rewritten)
        return nil
    end
    return fetch_style(function(css)
        if css and writeFile(path, css) then
            cb(rewritten)
        else
            cb(html)
        end
    end)
end

---@param value string|nil
---@return string
local function trimNulls(value)
    return (tostring(value or ""):gsub("%z.*$", ""):gsub("%s+$", ""))
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
        timeout = 90,
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
    return downloadBinaryAsync(absTarUrl(tar), referer, function(raw, err)
        if not raw then
            cb(nil, err)
            return
        end
        local src_map = {}
        for _idx, entry in ipairs(tarEntries(raw)) do
            local href = Shared.materializeImage(images_dir, entry.data)
            if href then
                local name = Text.basename(entry.name)
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

--- 把章节引用的插图、脚注图标、样式表落到书籍工作目录，并把引用改写为相对路径。
---@param book_id string
---@param chapter BookChapter
---@param html string
---@param referer string|nil
---@param fetch_style fun(done: fun(css: string|nil)): { cancel: fun() }|nil 拉整书样式表
---@param cb fun(html: string)
---@return { cancel: fun() }
function Assets.localizeAsync(book_id, chapter, html, referer, fetch_style, cb)
    local cancelled = false
    local jobs = {}
    local work_dir = Paths.bookWorkDir(book_id, "wechat")
    local images_dir = work_dir .. "/images"

    --- 图片落地后再补样式表；已取消则丢弃。
    ---@param out string
    local function afterImages(out)
        if cancelled then return end
        local job = localizeStyleAsync(work_dir, out, fetch_style, function(final)
            if not cancelled then cb(final) end
        end)
        if job then jobs[#jobs + 1] = job end
    end

    --- tar 资源包处理完后，先按包内映射改写 src，再补下仍指向 http(s) 的图片。
    ---@param src_map table<string, string> 原始 src → 本地相对路径
    local function afterTar(src_map)
        if cancelled then return end
        if not src_map["note.png"] and html:find(FOOTNOTE_SRC, 1, true) then
            src_map[FOOTNOTE_SRC] = footnoteHref(images_dir)
        end
        local rewritten = Shared.rewriteImageSources(html, src_map)
        local job = Shared.localizeAsync(rewritten, images_dir, function(url, done)
            return downloadBinaryAsync(url, WEB .. "/", done)
        end, afterImages)
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
            for _idx, job in ipairs(jobs) do
                if job.cancel then job:cancel() end
            end
        end }
end

return Assets
