--[[--
配置存储（通用 + 各源文件）

  .moon/settings/common.lua     跨源通用
  .moon/settings/<sourceId>.lua 各源专用

本模块只负责读写磁盘。
打开文件只调 Paths.ensureSettings，禁止 ensureLayout（循环依赖）。

@module koplugin.book.utils.settings
--]]

local LuaSettings = require("luasettings")
local Paths = require("utils.paths")
local logger = require("logger")

---@class MoonCommonSettings
---@field active_source SourceId 当前数据源 id
---@field ui_scale number UI 缩放百分比（默认 130）
---@field reader_float_menu boolean 阅读器中部点击悬浮菜单
---@field ui_font string|nil 界面字体 id：空=系统默认；本地为 basename；微信为 weread id
---@field ui_font_name string|nil 界面字体展示名

local M = {}

--- Default common settings
local function commonDefaults()
    return {
        active_source = "moon",
        ui_scale = 130,
        reader_float_menu = true,
        ui_font = "",
        ui_font_name = "",
    }
end

--- Fill missing defaults, returns true if any key added
local function fillDefaults(data, defaults)
    local dirty = false
    for k, v in pairs(defaults) do
        if data[k] == nil then
            data[k] = v
            dirty = true
        end
    end
    return dirty
end

-- internal helper to open a settings file
local function openFile(path)
    Paths.ensureSettings()
    logger.dbg("book.settings open", path)
    return LuaSettings:open(path)
end
-- Open source-specific settings file
local function openSource(id)
    id = id or "moon"
    return openFile(Paths.sourcePath(id))
end
--- Common configuration -----------------------------------------------------
function M.getCommon()
    local ls = openFile(Paths.commonPath())
    local dirty = false
    -- ensure defaults exist
    for k, v in pairs(commonDefaults()) do
        if ls.data[k] == nil then
            ls.data[k] = v
            dirty = true
        end
    end
    if dirty then
        ls:flush()
        logger.dbg("book.settings common defaults flushed")
    end
    return ls.data
end

local function openCommon()
    local ls = openFile(Paths.commonPath())
    local dirty = fillDefaults(ls.data, commonDefaults())
    if dirty then
        ls:flush()
        logger.dbg("book.settings common defaults flushed")
    end
    return ls
end

---@return MoonCommonSettings
function M.get()
    return openCommon().data
end

---@param s MoonCommonSettings|table|nil
function M.save(s)
    local ls = openCommon()
    if type(s) == "table" then
        ls:reset(s)
    end
    ls:flush()
    logger.dbg("book.settings save common", ls.data.active_source)
end

--- 源配置表
---@param id SourceId|nil
---@return table
function M.getSource(id)
    return openSource(id or M.activeSourceId()).data
end

---@param id SourceId|nil
---@param s table|nil
function M.saveSource(id, s)
    id = id or M.activeSourceId()
    local ls = openSource(id)
    if type(s) == "table" and s ~= ls.data then
        ls:reset(s)
    end
    ls:flush()
    logger.dbg("book.settings save source", id)
end

---@return SourceId
function M.activeSourceId()
    local c = M.get()
    return c.active_source or "moon"
end


function M.ensureDeviceId()
    local id = G_reader_settings:readSetting("device_id")
    if type(id) == "string" and id ~= "" then
        return id
    end
    -- KOReader 通常已有 device_id；缺失时本地生成并持久化
    id = string.format(
        "book-%08x%08x",
        math.floor(math.random() * 0xffffffff),
        os.time() % 0xffffffff
    )
    G_reader_settings:saveSetting("device_id", id)
    return id
end

return M
