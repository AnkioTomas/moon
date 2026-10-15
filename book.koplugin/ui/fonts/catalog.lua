--[[--
字体目录：可选字体列表与微信读书字体下载。

列表顺序：微信读书 → 用户（设置目录 fonts 根目录）→ 本地（fonts 子目录）→ 系统（FontList 其余路径，含 /mnt/us/fonts）。
扫描走 Job 子进程；微信列表走 Request.get 的 http.Cache（持久化，TTL 内不联网）。

@module koplugin.book.ui.fonts.catalog
--]]

local Archiver = require("ffi/archiver")
local FontList = require("fontlist")
local JSON = require("json")
local logger = require("utils.log")
local Cache = require("http.cache")
local Request = require("http.request")
local Paths = require("utils.paths")
local Job = require("workers.job")
local Text = require("utils.text")
local Fonts = require("ui.fonts")
local _ = require("gettext")

local Catalog = {}

local LIST_URL = "https://weread.qq.com/feconfig/font/list?type=web_v2"
local LIST_TTL = 7 * 24 * 3600 -- 7 天

--- 本地可选扩展名（不含 woff：微信下载落在 .moon/fonts）
local LOCAL_EXT = { ttf = true, ttc = true, cff = true, otf = true }

--- 本地扫描结果（用户在前、本地在后），一个会话只扫一次：扫描要起子进程，子进程里加载的
--- FontList 回不到主进程，每次重扫就是每次都卡。KOReader 的 FontList 本身也是会话级的，新放入的字体重启后出现。
---@type MoonFontItem[]|nil
local scanned

---@class MoonFontItem
---@field id string 写入 ui_font
---@field name string
---@field kind string "weread"|"user"|"local"|"system"
---@field url string|nil
---@field preview string|nil
---@field zip_size number|nil

local function byName(a, b) return a.name < b.name end

--- 字体登记的任一中文名。OpenType name ID：4 = 全名，1 = 族名（与 getLocalizedFontName 同序）。
---@param names table|nil fontinfo 的 names：语言 → { [name_id] = string }
---@return string|nil
local function chineseName(names)
    for _idx, lang in ipairs({ "zh-tw", "zh-hk", "zh-cn", "zh-sg" }) do
        local n = names and names[lang]
        if n and (n[4] or n[1]) then return n[4] or n[1] end
    end
end

--- 设置目录 fonts：根目录 = 用户 user，子目录 = 本地 local；FontList 其余路径 = 系统 system。
--- 按 basename 去重；显示名：界面语言的本地化名 → 中文界面退回任一中文名（只登记 zh-cn 的字体在 zh_TW 下
--- getLocalizedFontName 取不到）→ 字体族名 → 文件名。
---@return MoonFontItem[]
local function scanInstalledFonts()
    local seen, groups = {}, { user = {}, ["local"] = {}, system = {} }
    local zh = (_.current_lang or ""):match("^zh")
    local function add(path, kind)
        local file = Text.basename(path)
        if seen[file] or not LOCAL_EXT[file:lower():match("%.([^.]+)$")] then return end
        seen[file] = true
        local info = FontList.fontinfo[path]
        info = info and info[1]
        -- 粗体/斜体是同族变体：阅读页按族名 setFontFace 只会落到常规体，列出来选了也不生效
        if info and (info.bold or info.italic) then return end
        local name = FontList:getLocalizedFontName(path, 0) or (zh and info and chineseName(info.names))
            or (info and info.name) or file:gsub("%.[^%.]+$", "")
        table.insert(groups[kind], { id = file, name = name, kind = kind })
    end
    -- getFontList 载入 fontinfo 缓存；设置目录不一定在其扫描范围内，_readList 顺带采集 fontinfo，
    -- 追加的路径只活在子进程里。
    local root = Fonts.settingsFontsDir()
    local fontlist = FontList:getFontList()
    local n = #fontlist
    FontList:_readList(root, {})
    for i = n + 1, #fontlist do
        add(fontlist[i], fontlist[i]:match("^(.*)/") == root and "user" or "local")
    end
    for i = 1, n do
        add(fontlist[i], "system")
    end
    local out = {}
    for _idx, kind in ipairs({ "user", "local", "system" }) do
        table.sort(groups[kind], byName)
        for _i, it in ipairs(groups[kind]) do out[#out + 1] = it end
    end
    return out
end

--- 微信读书字体列表。http.Cache 只存 HTTP 200：强制门户等返回的 200 非 JSON 也会被缓存，
--- 解析失败时必须清掉，否则整个 TTL 内都拿不到列表。
---@param cb fun(items: MoonFontItem[]|nil, err: string|nil)
---@return { cancel: fun() }
local function fetchWereadAsync(cb)
    return Request.get(LIST_URL, { cache_ttl = LIST_TTL, accept = "application/json" }, function(body, err)
        if not body then return cb(nil, err or _("获取字体列表失败")) end
        local ok, data = pcall(JSON.decode, body)
        if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
            Cache.clear(LIST_URL)
            return cb(nil, _("字体列表解析失败"))
        end
        local out = {}
        for _idx, it in ipairs(data.items) do
            local id = type(it) == "table" and (it.id or it.font)
            if id and it.url then
                out[#out + 1] = {
                    id = tostring(id),
                    name = tostring(it.name or it.fontName or id),
                    kind = "weread",
                    url = it.url,
                    preview = it.preview or it.previewImageUrl or it.preview_image_url,
                    zip_size = it.zip_size or it.zipSize,
                }
            end
        end
        table.sort(out, byName)
        cb(out)
    end)
end

--- 异步列表：本地扫描（子进程，会话内只跑一次）与微信列表并发，都到齐后合并回调一次。
--- 任一路的错误都带回给调用方，但列表仍按已有结果给出。
---@param cb fun(items: MoonFontItem[], err: string|nil)
---@return { cancel: fun() }
function Catalog.listAsync(cb)
    local cancelled, pending = false, scanned and 1 or 2
    local weread, err
    local function finish(e)
        err = err or e
        pending = pending - 1
        if cancelled or pending > 0 then return end
        local out = {}
        for _idx, list in ipairs({ weread or {}, scanned or {} }) do
            for _i, it in ipairs(list) do out[#out + 1] = it end
        end
        cb(out, err)
    end

    local scan_job = not scanned and Job.run(scanInstalledFonts, {
        name = "font.scan",
        kind = "medium",
        on_done = function(data)
            scanned = data
            finish()
        end,
        on_failed = function(e)
            logger.warn("book.font scan failed", e)
            finish(e or _("字体扫描失败"))
        end,
    })
    local net_job = fetchWereadAsync(function(items, e)
        weread = items
        finish(e)
    end)

    return { cancel = function()
            cancelled = true
            if scan_job then scan_job:cancel() end
            net_job.cancel()
        end }
end

--- 从下载的 zip 里抽出第一个 .woff/.woff2，转成 sfnt 落到 dest；返回失败原因（nil 为成功）。
--- 无论成功失败都删掉 zip 和中间的 .woff。在 Job 子进程里执行（会阻塞地解压）。
---@param zip_path string
---@param dest string
---@return string|nil err
local function extractInstalledFont(zip_path, dest)
    local f = io.open(zip_path, "rb")
    local magic = f and f:read(4)
    if f then f:close() end
    local err
    if magic ~= "PK\3\4" then
        -- 强制门户 / CDN 错误页等以 200 返回的非 zip 内容
        err = "not a zip: " .. string.format("%q", (magic or ""):gsub("%c", "?"))
    else
        local woff = dest:gsub("%.ttf$", ".woff")
        local arc = Archiver.Reader:new()
        err = "no woff in zip"
        if arc:open(zip_path) then
            for entry in arc:iterate() do
                local path = entry.path:lower()
                -- 跳过 macOS 打包残留的 __MACOSX/._xxx.woff 资源叉
                if entry.mode == "file" and path:match("%.woff2?$") and not path:match("^__macosx/") then
                    -- libarchive 在 vfat 等盘上设属性时可能回 ARCHIVE_WARN（返回 false）但文件已完整写出：按落盘大小判定
                    arc:extractToPath(entry.path, woff)
                    local out = io.open(woff, "rb")
                    local size = out and out:seek("end")
                    if out then out:close() end
                    if size ~= tonumber(entry.size) then
                        err = "extract failed: " .. tostring(arc.err) .. " " .. tostring(size) .. "/" .. tostring(entry.size)
                    else
                        err = nil
                    end
                    break
                end
            end
        else
            err = "open zip failed: " .. tostring(arc.err)
        end
        arc:close()
        if not (not err and Fonts.finalizeWoff(woff, dest)) then
            os.remove(woff)
            err = err or "finalize failed"
        end
    end
    os.remove(zip_path)
    return err
end

--- 确保字体可用：微信读书字体未下载时下载 zip 并在子进程解压；其余直接回调成功。
--- 下载前先删掉残留 zip，避免续用上次中断的半截包。
---@param item MoonFontItem
---@param on_progress fun(bytes: number)|nil 下载字节进度
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Catalog.ensureInstalledAsync(item, on_progress, cb)
    local noop = { cancel = function() end }
    if item.kind ~= "weread" or Fonts.downloadedPath(item.id) then
        cb(true)
        return noop
    end
    local dest = Fonts.wereadPath(item.id)
    if not dest then
        cb(nil, _("无效字体项"))
        return noop
    end
    Paths.ensureFonts()
    local zip_path = dest:gsub("%.ttf$", ".zip")
    local cancelled = false
    local extract_job
    os.remove(zip_path)
    local download_job = Request.download({ url = item.url, timeout = require("http.timeout").net(10), on_progress = on_progress },
        zip_path, function(ok, err)
            if cancelled then return end
            if not ok then return cb(nil, err) end
            local function done(extract_err)
                if cancelled then return end
                if not Fonts.isFile(dest) then
                    logger.warn("book.font extract failed", item.id, extract_err)
                    return cb(nil, _("字体解压失败"))
                end
                logger.info("book.font installed", item.id, dest)
                cb(true)
            end
            extract_job = Job.run(function() return extractInstalledFont(zip_path, dest) end,
                { name = "font.extract", kind = "heavy", on_done = done, on_failed = done })
        end)
    return { cancel = function()
            cancelled = true
            download_job.cancel()
            if extract_job then extract_job:cancel() end
        end }
end

return Catalog
