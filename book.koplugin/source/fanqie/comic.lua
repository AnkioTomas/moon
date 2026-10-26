--[[--
番茄漫画章节（book_type=1）：正文不是 HTML，而是 {"picInfos":[{"picUrl":…}],"encrypt":true,"encrypt_key":"<hex>"}；
每张图就是一页，CDN 给的是 AES-256-GCM 密文 [12B IV][密文][16B 标签]。

@module koplugin.book.source.fanqie.comic
--]]

local Aes = require("crypto.aes")
local Gcm = require("crypto.gcm")
local Cbz = require("source.cbz")
local Image = require("utils.image")
local Paths = require("utils.paths")
local _ = require("gettext")

local Comic = {}

--- 章节正文是漫画 JSON 则返回页图地址列表与解密密钥（未加密为 nil）；否则返回 nil。
---@param raw string
---@return string[]|nil urls, string|nil key
function Comic.parse(raw)
    local s = raw:match("^%s*(.-)%s*$")
    if s:sub(1, 1) ~= "{" then return nil end
    local ok, data = pcall(require("json").decode, s)
    if not ok or type(data) ~= "table" or type(data.picInfos) ~= "table" then return nil end
    local urls = {}
    for _idx, pic in ipairs(data.picInfos) do
        if type(pic.picUrl) == "string" then urls[#urls + 1] = pic.picUrl end
    end
    if #urls == 0 then return nil end
    local key = data.encrypt == true and type(data.encrypt_key) == "string" and Aes.from_hex(data.encrypt_key) or nil
    return urls, key
end

---@param data string 下载到的页图
---@param key string|nil
---@return string|nil
function Comic.decrypt(data, key)
    if not key then return data end
    if #data <= 28 then return nil end
    return Gcm.ctr(key, data:sub(1, 12), data:sub(13, -17))
end

--- 逐页下载、解密、打成 CBZ；页图先落在同名目录，打包成功后由 Cbz 删掉。
---@param urls string[]
---@param key string|nil
---@param archive_path string
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Comic.materializeAsync(urls, key, archive_path, cb)
    local dir = archive_path:gsub("%.cbz$", "")
    local ok, dir_err = Paths.ensureDir(dir)
    local state, paths, current = { cancelled = false }, {}, 1
    local function nextPage()
        if state.cancelled then return end
        local url = urls[current]
        if not url then
            Cbz.build(paths, archive_path, state, function(path, err)
                require("libs/libkoreader-lfs").rmdir(dir)
                cb(path, err)
            end)
            return
        end
        state.active = require("http.request").request({
            url = url,
            method = "GET",
            timeout = require("http.timeout").net(3),
            allow_redirects = true,
        }, function(res)
            state.active = nil
            if state.cancelled then return end
            local data = res and res.code == 200 and res.body and Comic.decrypt(res.body, key)
            local ext = data and Image.ext(data)
            if not ext then cb(nil, _("漫画图片下载失败")); return end
            local path = string.format("%s/%04d%s", dir, current, ext)
            local file, err = io.open(path, "wb")
            if not file then cb(nil, err); return end
            file:write(data --[[@as string]])
            file:close()
            paths[current] = path
            current = current + 1
            nextPage()
        end)
    end
    if not ok then
        require("ui/uimanager"):nextTick(function() cb(nil, dir_err) end)
    else
        nextPage()
    end
    return { cancel = function()
            state.cancelled = true
            if state.active then state.active.cancel() end
            if state.writer then state.writer:close() end
            os.remove(archive_path .. ".part")
        end }
end

return Comic
