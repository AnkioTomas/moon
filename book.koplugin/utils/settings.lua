--[[--
配置存储。

common.lua 只保存跨功能的全局状态；功能配置分别保存到
settings/<section>.lua。统一提供 get()/save() 外观，避免调用方感知存储布局。

@module koplugin.book.utils.settings
--]]

local LuaSettings = require("luasettings")
local Paths = require("utils.paths")

local M = {}

local DEFAULTS = {
    common = {
        active_source = "local",
    },
    display = {
        ui_scale = 130, ui_font = "", ui_font_name = "", grid_max_cols = 4,
    },
    lockscreen = {
        lock_screen = "compose",
        lock_screen_background = "bing",
        lock_screen_component = "current",
        lock_screen_position = "center-center",
        lock_screen_wide = true,
        lock_screen_bill_period = "7d",
        lock_screen_custom_message = "读书不觉已春深，一寸光阴一寸金。",
        lock_screen_asset_cache = {},
    },
    remote = { remote_port = 9528, remote_autostart = false },
    pinyin = { pinyin_enabled = false },
    quickpanel = {
        quick_panel_actions = { "night", "wifi" },
        quick_panel_reader_actions = { "toc", "font", "reflow", "highlights", "xray", "dictionary", "ocr" },
    },
    reader = {
        book_xray_show_marks = true,
    },
    home = {
        home_layout = { "recent_list" },
        home_recent_list_mode = "hero_grid",
        home_excerpt_index = 0,
    },
    ai = { ai_endpoint = "", ai_api_key = "", ai_model = "" },
}

local SECTIONS = { "common", "display", "lockscreen", "remote", "pinyin", "quickpanel", "reader", "home", "ai" }
local KEY_SECTION = {}
for section, defaults in pairs(DEFAULTS) do
    for key in pairs(defaults) do KEY_SECTION[key] = section end
end
-- These are runtime/cache values, not user-facing defaults, but belong beside
-- the lockscreen settings rather than in common.lua.
for _, key in ipairs({
    "lock_screen_day", "lock_screen_bill_period", "lock_screen_quote_cache",
    "lock_screen_quote_source_cache", "lock_screen_quote_index",
    "lock_screen_component", "lock_screen_position", "lock_screen_wide",
    "lock_screen_custom_message", "lock_screen_asset_cache",
}) do
    KEY_SECTION[key] = "lockscreen"
end
for _, key in ipairs({ "pinyin_dict_built_at", "pinyin_dict_sha256", "pinyin_dict_source" }) do
    KEY_SECTION[key] = "pinyin"
end
KEY_SECTION.enabled_sources = "common"

local _files = {}
local _merged
local _initialized = false

local function copyValue(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, nested in pairs(value) do out[key] = nested end
    return out
end

local function fillDefaults(data, defaults)
    local dirty = false
    for key, value in pairs(defaults or {}) do
        if data[key] == nil then
            data[key] = copyValue(value)
            dirty = true
        end
    end
    return dirty
end

local function openFile(path)
    local ls = _files[path]
    if ls then return ls end
    Paths.ensureSettings()
    ls = LuaSettings:open(path)
    _files[path] = ls
    return ls
end

local function sectionFile(section)
    return openFile(section == "common" and Paths.commonPath() or Paths.sectionPath(section))
end

local function initialize()
    if _initialized then return end
    _initialized = true

    local common = sectionFile("common")
    local old = {}
    for key, value in pairs(common.data) do old[key] = value end
    local common_dirty = false

    for _, section in ipairs(SECTIONS) do
        local file = sectionFile(section)
        local dirty = false
        for key, value in pairs(old) do
            if KEY_SECTION[key] == section and file.data[key] == nil then
                file.data[key] = value
                common.data[key] = nil
                dirty, common_dirty = true, true
            end
        end
        if fillDefaults(file.data, DEFAULTS[section]) then dirty = true end
        if dirty then file:flush() end
    end
    if common.data.enabled_sources == nil and old.enabled_sources ~= nil then
        common.data.enabled_sources = old.enabled_sources
        common_dirty = true
    end
    if fillDefaults(common.data, DEFAULTS.common) then common_dirty = true end
    if common.data.active_source == "rss" then
        common.data.active_source = "local"
        common_dirty = true
    end
    if type(common.data.enabled_sources) == "table" and common.data.enabled_sources.rss ~= nil then
        common.data.enabled_sources.rss = nil
        common_dirty = true
    end
    if common_dirty then common:flush() end
end

local function buildMerged()
    local merged = {}
    for _, section in ipairs(SECTIONS) do
        for key, value in pairs(sectionFile(section).data) do merged[key] = value end
    end
    return merged
end

local function refreshMerged()
    local fresh = buildMerged()
    if not _merged then
        _merged = fresh
        return
    end
    for key in pairs(_merged) do _merged[key] = nil end
    for key, value in pairs(fresh) do _merged[key] = value end
end

--- Return all functional settings, or one section when named.
---@param section string|nil
---@return table
function M.get(section)
    initialize()
    if section then return sectionFile(section).data end
    if not _merged then _merged = buildMerged() end
    return _merged
end

local function saveMerged(values)
    for key, section in pairs(KEY_SECTION) do
        local file = sectionFile(section)
        -- Synchronize known keys, including nil deletions. This matters for
        -- callers that clear a value and then call save().
        file.data[key] = values[key]
    end
    for _, section in ipairs(SECTIONS) do sectionFile(section):flush() end
end

--- Persist all functional settings. The optional table keeps compatibility with
--- callers that pass the result of get().
---@param values table|nil
function M.save(values)
    initialize()
    saveMerged(values or _merged or buildMerged())
    refreshMerged()
end

--- Persist one functional section without merging unrelated settings.
---@param section string
---@param values table|nil
function M.saveSection(section, values)
    initialize()
    local file = sectionFile(section)
    if type(values) == "table" and values ~= file.data then file:reset(values) end
    file:flush()
    refreshMerged()
end

function M.getSource(id)
    initialize()
    return openFile(Paths.sourcePath(id or M.activeSourceId())).data
end

function M.saveSource(id, values)
    initialize()
    local file = openFile(Paths.sourcePath(id or M.activeSourceId()))
    if type(values) == "table" and values ~= file.data then file:reset(values) end
    file:flush()
end

function M.activeSourceId()
    return M.get("common").active_source or "local"
end

function M.ensureDeviceId()
    local id = G_reader_settings:readSetting("device_id")
    if type(id) == "string" and id ~= "" then return id end
    id = string.format("book-%08x%08x", math.floor(math.random() * 0xffffffff), os.time() % 0xffffffff)
    G_reader_settings:saveSetting("device_id", id)
    return id
end

return M
