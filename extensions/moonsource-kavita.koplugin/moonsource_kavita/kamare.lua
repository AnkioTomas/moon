--[[--
漫画交给 kamare 插件（fpammer/kamare.koplugin）在线看。

kamare 没有公开接口：这里 require 它的 `kamareimageviewer`（全屏查看器）与 `kavitaclient`
（Kavita REST 单例）。它一改名就会失效，所以全部调用都在 pcall 里，出错只返回错误，
调用方退回下载 + 内置阅读器。进度由 kamare 自己推给 Kavita。

@module moonsource_kavita.kamare
--]]

local _ = require("gettext")

local Kamare = {}

---@return boolean
function Kamare.available()
    local ok, viewer = pcall(require, "kamareimageviewer")
    return ok and type(viewer) == "table" and type(viewer.new) == "function"
end

--- kamare 的页尺寸接口页号有时从 0 起，查看器只认从 1 起；拿不到就不预热。
---@param client table
---@param chapter_id integer
---@return table|nil
local function dimensions(client, chapter_id)
    if type(client.getFileDimensions) ~= "function" then return nil end
    local dims, code = client:getFileDimensions(chapter_id)
    if type(dims) ~= "table" or type(code) ~= "number" or code < 200 or code >= 300 then return nil end
    local zero_based = false
    for _idx, d in ipairs(dims) do
        if d.pageNumber == 0 then zero_based = true end
    end
    if zero_based then
        for _idx, d in ipairs(dims) do
            if type(d.pageNumber) == "number" then d.pageNumber = d.pageNumber + 1 end
        end
    end
    return dims
end

---@class KamareOpenOpts
---@field base_url string
---@field api_key string
---@field entry table 目录里的一卷（chapterId/volumeId/libraryId/seriesId/pages）
---@field title string
---@field start_page integer 从 1 起
---@field on_close fun(page: integer, total: integer)
---@field on_next fun(chapter_id: any) 章末续读下一卷

---@param opts KamareOpenOpts
---@return table|nil viewer, string|nil err
local function open(opts)
    local Viewer = require("kamareimageviewer")
    local client = require("kavitaclient")
    local entry = opts.entry
    client.base_url, client.api_key, client.auth_method, client.bearer = opts.base_url, opts.api_key, "apiKey", nil
    if not client.device_id or client.device_id == "" then client.device_id = "moon-kavita" end
    local images = client:streamChapter(entry.chapterId)
    if type(images) ~= "table" then return nil, _("打开漫画阅读器失败") end
    local LuaSettings = require("luasettings")
    local viewer = Viewer:new{
        images_list_data = images,
        images_list_nb = entry.pages,
        title = opts.title,
        fullscreen = true,
        metadata = {
            seriesName = opts.title,
            seriesId = entry.seriesId,
            libraryId = entry.libraryId,
            volumeId = entry.volumeId,
            chapterId = entry.chapterId,
            chapter = { id = entry.chapterId, volumeId = entry.volumeId, pages = entry.pages },
            startPage = opts.start_page,
            content_type = "chapter",
        },
        preloaded_dimensions = dimensions(client, entry.chapterId),
        kamare_settings = LuaSettings:open(require("datastorage"):getSettingsDir() .. "/kamare.lua"),
        on_close_callback = opts.on_close,
        on_next_chapter_callback = function(next_id)
            require("ui/uimanager"):nextTick(function() opts.on_next(next_id) end)
        end,
    }
    if viewer._aborted then return nil, _("漫画阅读器已在运行") end
    require("ui/uimanager"):show(viewer)
    return viewer
end

--- 打开查看器。kamare 缺失、改了接口、抛错都只返回错误。
---@param opts KamareOpenOpts
---@return table|nil viewer, string|nil err
function Kamare.open(opts)
    if (tonumber(opts.entry.pages) or 0) <= 0 then return nil, _("这一卷没有可显示的页面") end
    local ok, viewer, err = pcall(open, opts)
    if not ok then
        require("utils.log").warn("kavita.kamare open failed", viewer)
        return nil, _("打开漫画阅读器失败")
    end
    return viewer, err
end

return Kamare
