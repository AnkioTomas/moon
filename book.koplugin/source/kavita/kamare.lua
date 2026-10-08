--[[--
Kavita 源 → 外部 kamare 阅读器适配层（漫画在线阅读）。

本模块**不复制** kamare 代码，只在运行时调用「已安装的 kamare 插件」暴露的
模块：``kamareimageviewer``（全屏阅读器类）与 ``kavitaclient``（Kavita REST
单例）。kamare 未安装/未启用时 :func:`available` 返回 false，源回落到原生
阅读器（下载 cbz 后交 KOReader）。

跨插件调用依赖：KOReader 会把所有启用插件的目录加入 ``package.path``
（``frontend/pluginloader.lua``），因此这里的 ``require`` 能解析到 kamare。
这是**非公开契约**，kamare 升级改名即会失效——故所有调用都包在 pcall 内，
失败一律回落到原生路径，绝不拖垮 moon。

@module koplugin.book.source.kavita.kamare
--]]

local UIManager = require("ui/uimanager")
local logger = require("utils.log")
local _ = require("gettext")

local Kamare = {}

local SOURCE_ID = "kavita"
local VIEWER_MODULE = "kamareimageviewer"
local CLIENT_MODULE = "kavitaclient"

--- 外部 kamare 阅读器是否可用（require 成功且带 ``new``）。
---@return boolean
function Kamare.available()
    local ok, mod = pcall(require, VIEWER_MODULE)
    return ok and type(mod) == "table" and type(mod.new) == "function"
end

--- 把 moon 的 Kavita 配置注入 kamare 客户端单例（base_url / api_key / 设备号）。
---@return table|nil client
---@return string|nil err
local function configureClient()
    local ok, Client = pcall(require, CLIENT_MODULE)
    if not ok or type(Client) ~= "table" then
        return nil, _("kamare 客户端不可用")
    end
    local Settings = require("utils.settings")
    local cfg = Settings.getSource(SOURCE_ID)
    if (cfg.base_url or "") == "" or (cfg.api_key or "") == "" then
        return nil, _("未配置服务器地址或 API Key")
    end
    Client.base_url = cfg.base_url
    Client.api_key = cfg.api_key
    Client.auth_method = "apiKey"
    Client.bearer = nil
    -- kamare 插件自身 init 时会灌设备号；缺失时兜个稳定值（同一设备复用）。
    if not Client.device_id or Client.device_id == "" then
        Client.device_id = cfg.device_id or "moon-kavita"
    end
    return Client
end

--- 打开 kamare 的持久化阅读设置（与其目录浏览器共用 ``settings/kamare.lua``）。
---@return table|nil
local function openSettings()
    local ok1, LuaSettings = pcall(require, "luasettings")
    local ok2, DataStorage = pcall(require, "datastorage")
    if not (ok1 and ok2) then return nil end
    local ok, settings = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/kamare.lua")
    end)
    return ok and settings or nil
end

--- 预取页尺寸（可选预热；失败返回 nil，不影响打开）。
---@param Client table
---@param chapter_id any
---@return table|nil
local function preloadedDimensions(Client, chapter_id)
    if type(Client.getFileDimensions) ~= "function" then return nil end
    local ok, dims, code = pcall(Client.getFileDimensions, Client, chapter_id)
    if not ok or type(dims) ~= "table" or type(code) ~= "number"
        or code < 200 or code >= 300 then
        return nil
    end
    -- kamare 浏览器把 0-based 页号归一到 1-based；viewer 只认归一后的结果。
    local zero_based = false
    for _, d in ipairs(dims) do
        local pn = d.pageNumber or d.page or d.page_num
        if type(pn) == "number" and pn == 0 then zero_based = true; break end
    end
    if zero_based then
        for _, d in ipairs(dims) do
            if type(d.pageNumber) == "number" then d.pageNumber = d.pageNumber + 1 end
            if type(d.page) == "number" then d.page = d.page + 1 end
            if type(d.page_num) == "number" then d.page_num = d.page_num + 1 end
        end
    end
    return dims
end

--- 启动 kamare 阅读器阅读一章漫画。
---@param opts table
---@field chapter table 章 toc 条目（``chapterId`` / ``volumeId`` / ``libraryId`` / ``seriesId`` / ``pages``）
---@field title string|nil 标题栏/系列名
---@field start_page number|nil 起始页（1-based，缺省 1）
---@field on_close fun(current_page: number, total_pages: number)|nil
---@field on_next_chapter fun(next_chapter_id: any)|nil 章末续章回调
---@return table|nil viewer
---@return string|nil err
function Kamare.open(opts)
    local ok, Viewer = pcall(require, VIEWER_MODULE)
    if not ok or type(Viewer) ~= "table" then
        return nil, _("kamare 阅读器不可用")
    end
    local chapter = opts.chapter or {}
    local chapter_id = chapter.chapterId or chapter.uid
    if chapter_id == nil then
        return nil, _("章节信息缺失")
    end
    local pages = tonumber(chapter.pages) or 0
    if pages <= 0 then
        return nil, _("本章没有可显示的页面")
    end
    local Client, cerr = configureClient()
    if not Client then return nil, cerr end

    -- streamChapter 是外部 kamare 的非公开方法，包 pcall：缺失或抛错都回退（源回落原生下载）。
    if type(Client.streamChapter) ~= "function" then
        return nil, _("kamare 阅读器不可用")
    end
    local stream_ok, images_list_data = pcall(Client.streamChapter, Client, chapter_id)
    if not stream_ok or type(images_list_data) ~= "table" then
        return nil, _("打开漫画阅读器失败")
    end

    local metadata = {
        seriesName = opts.title,
        seriesId = chapter.seriesId,
        libraryId = chapter.libraryId,
        volumeId = chapter.volumeId,
        chapterId = chapter_id,
        chapter = { id = chapter_id, volumeId = chapter.volumeId, pages = pages },
        startPage = tonumber(opts.start_page) or 1,
        content_type = "chapter",
    }

    local spec = {
        ui = nil, -- 传 ReaderUI 会被 _setupStatisticsInterface 猴补污染
        images_list_data = images_list_data,
        images_list_nb = pages,
        title = opts.title or chapter.title or _("漫画"),
        fullscreen = true,
        metadata = metadata,
        preloaded_dimensions = preloadedDimensions(Client, chapter_id),
        kamare_settings = openSettings(),
        on_close_callback = opts.on_close,
    }
    if opts.on_next_chapter then
        spec.on_next_chapter_callback = function(next_id)
            UIManager:nextTick(function() opts.on_next_chapter(next_id) end)
        end
    end

    local created, viewer = pcall(Viewer.new, Viewer, spec)
    if not created or not viewer then
        logger.err("kavita.kamare: viewer init failed:", viewer)
        return nil, _("打开漫画阅读器失败")
    end
    if viewer._aborted then
        return nil, _("阅读器已在运行")
    end
    if viewer.virtual_document and viewer.prefetchUpcomingTiles then
        pcall(viewer.prefetchUpcomingTiles, viewer)
    end
    UIManager:show(viewer)
    return viewer
end

return Kamare
