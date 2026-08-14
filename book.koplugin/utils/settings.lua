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

--- 通用配置默认值
---@return MoonCommonSettings
local function commonDefaults()
    return {
        active_source = "moon",
        ui_scale = 130,
        reader_float_menu = true,
        ui_font = "",
        ui_font_name = "",
    }
end

--- 补齐缺失默认键；有写入则返回 true
---@param data table
---@param defaults table
---@return boolean
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

--- 打开配置文件（先 ensureSettings）
---@param path string
---@return table LuaSettings 实例
local function openFile(path)
    Paths.ensureSettings()
    logger.dbg("book.settings open", path)
    return LuaSettings:open(path)
end

--- 打开源专用配置文件
---@param id SourceId|nil
---@return table LuaSettings 实例
local function openSource(id)
    id = id or "moon"
    return openFile(Paths.sourcePath(id))
end

--- 读通用配置表（缺键则补默认并 flush）
---@return MoonCommonSettings
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

--- 打开通用配置 LuaSettings（缺键则补默认并 flush）
---@return table LuaSettings 实例
local function openCommon()
    local ls = openFile(Paths.commonPath())
    local dirty = fillDefaults(ls.data, commonDefaults())
    if dirty then
        ls:flush()
        logger.dbg("book.settings common defaults flushed")
    end
    return ls
end

--- 读通用配置（data 表）
---@return MoonCommonSettings
function M.get()
    return openCommon().data
end

--- 写通用配置
---@param s MoonCommonSettings|table|nil
---@return nil
function M.save(s)
    local ls = openCommon()
    if type(s) == "table" then
        ls:reset(s)
    end
    ls:flush()
    logger.dbg("book.settings save common", ls.data.active_source)
end

--- 读源配置表
---@param id SourceId|nil
---@return table
function M.getSource(id)
    return openSource(id or M.activeSourceId()).data
end

--- 写源配置表
---@param id SourceId|nil
---@param s table|nil
---@return nil
function M.saveSource(id, s)
    id = id or M.activeSourceId()
    local ls = openSource(id)
    if type(s) == "table" and s ~= ls.data then
        ls:reset(s)
    end
    ls:flush()
    logger.dbg("book.settings save source", id)
end

--- 当前活跃数据源 id
---@return SourceId
function M.activeSourceId()
    local c = M.get()
    return c.active_source or "moon"
end

--- 确保 G_reader_settings.device_id 存在（缺失则生成并持久化）
---@return string
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
