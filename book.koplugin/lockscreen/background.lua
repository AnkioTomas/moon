--[[--
锁屏背景：custom / 必应 / 封面 / 摸鱼日报 / 书架海报墙；none 时由渲染器铺纯色。

@module koplugin.book.lockscreen.background
--]]

local lfs = require("libs/libkoreader-lfs")
local Request = require("http.request")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")

local M = {}

local BG_MODES = {
    custom = true,
    bing = true,
    cover = true,
    myrl = true,
    bookshelf = true,
    none = true,
}

---@param path string
---@return boolean
local function fileOk(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file" and (attr.size or 0) > 8
end

---@param mode string|nil
---@return boolean
function M.validMode(mode)
    return BG_MODES[mode] == true
end

---@return string
function M.customPath()
    return Paths.screensaverDir() .. "/custom.png"
end

---@return string
function M.bingPath()
    return Paths.screensaverDir() .. "/bing.jpg"
end

---@return string
function M.myrlPath()
    return Paths.screensaverDir() .. "/myrl.png"
end

---@return string
function M.bookshelfPath()
    return Paths.screensaverDir() .. "/bookshelf.png"
end

--- 最近在读书籍封面（本地缓存）；没有则 nil。
---@return string|nil
function M.coverPath()
    local ok, Context = pcall(require, "lockscreen.context")
    if not ok or not Context or not Context.currentBook then
        return nil
    end
    local book = Context.currentBook()
    local path = book and book.cover
    return fileOk(path) and path or nil
end

--- 返回当前可用背景，不触网、不渲染书架。
---@return string|nil
function M.current()
    local mode = MoonSettings.get().lock_screen_background or "bing"
    if mode == "custom" then
        return fileOk(M.customPath()) and M.customPath() or nil
    end
    if mode == "cover" then
        return M.coverPath()
    end
    if mode == "bing" and fileOk(M.bingPath()) then
        return M.bingPath()
    end
    if mode == "myrl" and fileOk(M.myrlPath()) then
        return M.myrlPath()
    end
    if mode == "bookshelf" and fileOk(M.bookshelfPath()) then
        return M.bookshelfPath()
    end
    return nil
end

--- 渲染书架海报墙到缓存文件（本地，不触网）。
---@param path string
---@return boolean, any
local function renderBookshelf(path)
    local Context = require("lockscreen.context")
    local Render = require("lockscreen.render")
    local Blitbuffer = require("ffi/blitbuffer")
    local _ = require("gettext")

    local PLACEHOLDER_TONES = {
        Blitbuffer.COLOR_GRAY_4,
        Blitbuffer.COLOR_GRAY_5,
        Blitbuffer.COLOR_GRAY_6,
        Blitbuffer.COLOR_DARK_GRAY,
        Blitbuffer.COLOR_GRAY_7,
    }

    local function hash(s)
        local h = 0
        for i = 1, #s do
            h = (h * 33 + s:byte(i)) % 2147483647
        end
        return h
    end

    local function collectPosters(data)
        local posters, seen = {}, {}
        local function push(book)
            local id = book.stable_id
            if type(id) ~= "string" or id == "" or seen[id] then
                return
            end
            seen[id] = true
            posters[#posters + 1] = book
        end
        for _, book in ipairs(data.reading or {}) do
            push(book)
        end
        for _, book in ipairs(data.covers or {}) do
            push(book)
        end
        return posters
    end

    local function pushPlaceholder(blocks, x, y, cw, ch, tone)
        local radius = math.max(4, math.floor(cw * 0.06))
        blocks[#blocks + 1] = {
            kind = "panel",
            x = x + 2, y = y + 2, width = cw, height = ch,
            radius = radius, color = Blitbuffer.COLOR_GRAY_D,
        }
        blocks[#blocks + 1] = {
            kind = "panel",
            x = x, y = y, width = cw, height = ch,
            radius = radius, color = tone,
        }
        local inset = math.max(6, math.floor(cw * 0.14))
        blocks[#blocks + 1] = {
            kind = "panel",
            x = x + inset, y = y + inset,
            width = cw - inset * 2, height = ch - inset * 2,
            radius = math.max(2, math.floor(radius * 0.6)),
            color = Blitbuffer.COLOR_GRAY_E,
        }
    end

    local function pushPoster(blocks, book, x, y, cw, ch, day)
        local radius = math.max(4, math.floor(cw * 0.06))
        if book.cover then
            blocks[#blocks + 1] = {
                kind = "image",
                path = book.cover,
                x = x, y = y, width = cw, height = ch,
                matte = Blitbuffer.COLOR_WHITE,
                inset = 0,
                border = false,
                shadow = 2,
                radius = radius,
            }
        else
            local tone = PLACEHOLDER_TONES[(hash((book.stable_id or "") .. "\0" .. day) % #PLACEHOLDER_TONES) + 1]
            pushPlaceholder(blocks, x, y, cw, ch, tone)
        end
    end

    local w, h = Render.size()
    local day = os.date("%Y-%m-%d")
    local posters = collectPosters(Context.bookshelf())
    local blocks = {
        {
            kind = "panel", x = 0, y = 0, width = w, height = h,
            color = Blitbuffer.COLOR_WHITE,
        },
    }

    local margin = math.max(12, math.floor(w * 0.04))
    local gap = math.max(8, math.floor(w * 0.022))
    local cols = w >= 560 and 4 or 3
    local cell_w = math.floor((w - margin * 2 - gap * (cols - 1)) / cols)
    local cell_h = math.floor(cell_w * 1.45)
    local rows = math.max(1, math.floor((h - margin * 2 + gap) / (cell_h + gap)))
    local capacity = cols * rows
    local grid_h = rows * cell_h + (rows - 1) * gap
    local grid_w = cols * cell_w + (cols - 1) * gap
    local origin_x = math.floor((w - grid_w) / 2)
    local origin_y = math.floor((h - grid_h) / 2)

    if #posters == 0 then
        blocks[#blocks + 1] = {
            text = _("书架还是空的"),
            x = margin, y = math.floor(h * 0.45),
            width = w - margin * 2, size = 22, align = "center", box = false,
            color = Blitbuffer.COLOR_GRAY_6,
        }
    else
        local n = math.min(#posters, capacity)
        for i = 1, n do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local x = origin_x + col * (cell_w + gap)
            local y = origin_y + row * (cell_h + gap)
            pushPoster(blocks, posters[i], x, y, cell_w, cell_h, day)
        end
    end

    Paths.ensureScreensaverDir()
    return Render.write(path, nil, blocks)
end

--- 下载摸鱼日报。
---@param cb fun(path: string|nil)
---@return table|nil
local function ensureMyrl(cb)
    local cancelled = false
    local today = os.date("%Y-%m-%d")
    local c = MoonSettings.get()
    local cached = M.myrlPath()
    if c.lock_screen_myrl_day == today and fileOk(cached) then
        cb(cached)
        return nil
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        cb(fileOk(cached) and cached or nil)
        return nil
    end
    Paths.ensureScreensaverDir()
    local Layout = require("lockscreen.layout")
    local w, h = Layout.portraitSize()
    local tmp = cached .. ".part"
    local request_job = Request.download({
        url = string.format("https://api.ankio.net/myrl?ink=1&width=%d&height=%d", w, h),
        method = "GET",
        timeout = 60,
    }, tmp, function(ok)
        if cancelled then
            os.remove(tmp)
            return
        end
        if ok and os.rename(tmp, cached) then
            c.lock_screen_myrl_day = today
            MoonSettings.save()
            cb(cached)
        else
            os.remove(tmp)
            cb(fileOk(cached) and cached or nil)
        end
    end)
    return {
        cancel = function()
            cancelled = true
            if request_job and request_job.cancel then
                request_job.cancel()
            end
        end,
    }
end

--- 确保背景可用。
---@param cb fun(path: string|nil)
---@return table|nil 可取消的下载任务；本地命中时返回 nil
function M.ensure(cb)
    local cancelled = false
    local c = MoonSettings.get()
    local mode = c.lock_screen_background or "bing"
    if mode == "none" then
        cb(nil)
        return nil
    end
    if mode == "custom" then
        cb(fileOk(M.customPath()) and M.customPath() or nil)
        return nil
    end
    if mode == "cover" then
        cb(M.coverPath())
        return nil
    end
    if mode == "bookshelf" then
        local path = M.bookshelfPath()
        local ok = renderBookshelf(path)
        cb(ok and fileOk(path) and path or nil)
        return nil
    end
    if mode == "myrl" then
        return ensureMyrl(cb)
    end

    -- bing（默认）
    local today = os.date("%Y-%m-%d")
    local cached = M.bingPath()
    if c.lock_screen_bing_day == today and fileOk(cached) then
        cb(cached)
        return nil
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        cb(fileOk(cached) and cached or nil)
        return nil
    end
    Paths.ensureScreensaverDir()
    local tmp = cached .. ".part"
    local request_job = Request.download({
        url = "https://api.ankio.net/bing",
        method = "GET",
        allow_redirects = true,
        timeout = 60,
    }, tmp, function(ok)
        if cancelled then
            os.remove(tmp)
            return
        end
        if ok and os.rename(tmp, cached) then
            c.lock_screen_bing_day = today
            MoonSettings.save()
            cb(cached)
        else
            os.remove(tmp)
            cb(fileOk(cached) and cached or nil)
        end
    end)
    return {
        cancel = function()
            cancelled = true
            if request_job and request_job.cancel then
                request_job.cancel()
            end
        end,
    }
end

return M
