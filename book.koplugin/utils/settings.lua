--[[--
配置存储（通用 + 各源文件）

  .moon/settings/common.lua     跨源通用
  .moon/settings/<sourceId>.lua 各源专用

本模块只负责读写磁盘。每个文件进程内只打开一次，之后读走内存、写走 flush。
打开文件只调 Paths.ensureSettings，禁止 ensureLayout（循环依赖）。

@module koplugin.book.utils.settings
--]]

local LuaSettings = require("luasettings")
local Paths = require("utils.paths")

---@class MoonCommonSettings
---@field active_source SourceId 当前数据源 id
---@field enabled_sources table<SourceId, boolean>|nil 启用源集合；nil = 全部启用（兼容旧配置）
---@field ui_scale number UI 缩放百分比（默认 130）
---@field ui_font string|nil 界面字体 id：空=系统默认；本地为 basename；微信为 weread id
---@field ui_font_name string|nil 界面字体展示名
---@field grid_max_cols number 网格最大列数（2～6，默认 4）
---@field lock_screen string|nil 锁屏显示：ko=跟随系统；myrl=摸鱼日报
---@field lock_screen_prev_type string|nil 接管前的 screensaver_type
---@field lock_screen_prev_cover string|nil 接管前的 screensaver_document_cover（空串=无）
---@field lock_screen_myrl_day string|nil 摸鱼日报上次成功下载日 YYYY-MM-DD

local M = {}

--- 通用配置默认值
---@return MoonCommonSettings
local function commonDefaults()
    return {
        active_source = "moon",
        ui_scale = 130,
        ui_font = "",
        ui_font_name = "",
        grid_max_cols = 4,
        lock_screen = "ko",
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

--- 已打开的配置文件：path → LuaSettings。
--- LuaSettings:open 每次都 dofile 重新解析文件，而 UI.sz/UI.face 每次调用都要读
--- ui_scale，一个页面就是几百次。实例必须常驻，不能每次读配置都重开文件。
local _files = {}

--- 打开配置文件（进程内只开一次；首次补齐默认键）
---@param path string
---@param defaults table|nil
---@return table LuaSettings 实例
local function openFile(path, defaults)
    local ls = _files[path]
    if ls then
        return ls
    end
    Paths.ensureSettings()
    ls = LuaSettings:open(path)
    _files[path] = ls
    if defaults and fillDefaults(ls.data, defaults) then
        ls:flush()
    end
    return ls
end

--- 读通用配置（data 表）
---@return MoonCommonSettings
function M.get()
    return openFile(Paths.commonPath(), commonDefaults()).data
end

--- 写通用配置
---@param s MoonCommonSettings|table|nil
---@return nil
function M.save(s)
    local ls = openFile(Paths.commonPath(), commonDefaults())
    if type(s) == "table" and s ~= ls.data then
        ls:reset(s)
    end
    ls:flush()
end

--- 读源配置表
---@param id SourceId|nil
---@return table
function M.getSource(id)
    return openFile(Paths.sourcePath(id or M.activeSourceId())).data
end

--- 写源配置表
---@param id SourceId|nil
---@param s table|nil
---@return nil
function M.saveSource(id, s)
    id = id or M.activeSourceId()
    local ls = openFile(Paths.sourcePath(id))
    if type(s) == "table" and s ~= ls.data then
        ls:reset(s)
    end
    ls:flush()
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
