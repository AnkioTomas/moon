--[[--
Moon 配置存储

  .moon/settings/common.lua          通用设置
  .moon/settings/moon.lua 等         各数据源专用设置

@module koplugin.book.moon.settings
--]]

local LuaSettings = require("luasettings")
local Paths = require("moon.paths")

local M = {}

local SOURCE_IDS = { "moon", "webdav", "wechat", "legado" }

local _common_ls = nil
local _source_ls = {}

local function commonDefaults()
    return {
        active_source = "moon",
        auto_sync = true,
        auto_stats = true,
        open_on_start = true,
        home_header = "clock",
        ui_scale = 130,
        reader_float_menu = true,
    }
end

local function sourceDefaults(id)
    if id == "moon" then
        return { base_url = "", token = "" }
    end
    return {}
end

local function openFile(path)
    Paths.ensureLayout()
    return LuaSettings:open(path)
end

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

local function normalizeCommon(s)
    if s.home_header ~= "hitokoto" then
        s.home_header = s.home_header or "clock"
    end
    if not s.active_source or s.active_source == "" then
        s.active_source = "moon"
    end
    s.library_dir = nil
    s.base_url = nil
    s.token = nil
    s.sources = nil
    return s
end

local function openCommon()
    if _common_ls then
        return _common_ls
    end
    Paths.ensureLayout()
    _common_ls = openFile(Paths.commonPath())
    local dirty = fillDefaults(_common_ls.data, commonDefaults())
    normalizeCommon(_common_ls.data)
    if dirty then
        _common_ls:flush()
    end
    return _common_ls
end

local function openSource(id)
    id = id or "moon"
    if _source_ls[id] then
        return _source_ls[id]
    end
    Paths.ensureLayout()
    local ls = openFile(Paths.sourcePath(id))
    local dirty = fillDefaults(ls.data, sourceDefaults(id))
    if dirty then
        ls:flush()
    end
    _source_ls[id] = ls
    return ls
end

--- 通用设置（与磁盘同一引用）；改完必须 save / saveCommon
function M.get()
    return normalizeCommon(openCommon().data)
end

M.getCommon = M.get

function M.save(s)
    local ls = openCommon()
    if type(s) == "table" and s ~= ls.data then
        ls:reset(normalizeCommon(s))
    else
        normalizeCommon(ls.data)
    end
    ls:flush()
end

M.saveCommon = M.save

--- 数据源专用设置
function M.getSource(id)
    return openSource(id or "moon").data
end

function M.saveSource(id, s)
    id = id or "moon"
    local ls = openSource(id)
    if type(s) == "table" and s ~= ls.data then
        local data = sourceDefaults(id)
        for k, v in pairs(s) do
            data[k] = v
        end
        ls:reset(data)
    end
    ls:flush()
end

function M.activeSourceId()
    local c = M.get()
    return c.active_source or "moon"
end

function M.sourceIds()
    return SOURCE_IDS
end

function M.reload()
    _common_ls = nil
    _source_ls = {}
    return M.get()
end

return M
