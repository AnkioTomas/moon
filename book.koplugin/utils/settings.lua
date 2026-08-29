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
        book_xray_enabled = true,
        book_xray_show_marks = true,
        book_reader_top_bar = true,
        book_reader_bottom_bar = true,
        edge_translation_enabled = true,
        baike_enabled = true,
        reader_popup_buttons = {
            select = true,
            highlight = true,
            copy = true,
            add_note = true,
            wikipedia = true,
            dictionary = true,
            translate = true,
            view_html = true,
            qrcode = true,
            search = true,
        },
        translate_languages = { "en", "zh", "ja", "fr", "de", "ko", "es", "ru", "zh_TW" },
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

--- 复制默认值，递归拷贝表，避免嵌套配置共享 DEFAULTS 的子表。
---@param value any
---@return any
local function copyValue(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, nested in pairs(value) do out[key] = copyValue(nested) end
    return out
end

--- 就地补齐 data 里缺失的默认键；已有值（含 false）一律保留。
---@param data table 目标配置表（原地修改）
---@param defaults table|nil
---@return boolean dirty 是否补过键，调用方据此决定要不要 flush
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

--- 按路径打开并缓存 LuaSettings 实例。
--- 同一路径全程复用一个实例：多份实例会各自持有 data 副本，flush 时互相覆盖。
---@param path string
---@return table LuaSettings
local function openFile(path)
    local ls = _files[path]
    if ls then return ls end
    Paths.ensureSettings()
    ls = LuaSettings:open(path)
    _files[path] = ls
    return ls
end

--- 取某个配置分区的 LuaSettings；common 落 common.lua，其余落 settings/<section>.lua。
---@param section string
---@return table LuaSettings
local function sectionFile(section)
    return openFile(section == "common" and Paths.commonPath() or Paths.sectionPath(section))
end

--- 首次访问配置时做一次迁移与补默认，只跑一遍。
--- 迁移方向：老版本全塞在 common.lua 的键，按 KEY_SECTION 搬到各分区文件，
--- 分区已有该键则以分区值为准（不回写覆盖），搬走后从 common 删除。
--- 顺带把已下线的 rss 源从 active_source / enabled_sources 里剔掉。
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

--- 把所有分区平铺成一张表，供 get() 的无参形态返回。
--- 键跨分区重名时按 SECTIONS 顺序后者胜出（实际不存在重名）。
---@return table
local function buildMerged()
    local merged = {}
    for _, section in ipairs(SECTIONS) do
        for key, value in pairs(sectionFile(section).data) do merged[key] = value end
    end
    return merged
end

--- 用磁盘最新内容刷新平铺表，就地清空再填。
--- 必须复用同一个表对象：调用方普遍长期持着 get() 的返回值，换新表会让它们读到旧快照。
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

--- 把平铺表按 KEY_SECTION 回写到各分区文件并全部 flush。
--- 默认只写入 values 中出现的键；replace=true 时缺键才会被清除。
---@param values table 平铺的配置值
---@param replace boolean|nil
local function saveMerged(values, replace)
    for key, section in pairs(KEY_SECTION) do
        local file = sectionFile(section)
        if replace or values[key] ~= nil then
            file.data[key] = values[key]
        end
    end
    for _, section in ipairs(SECTIONS) do sectionFile(section):flush() end
end

--- Persist settings. Partial tables are merged; get()'s live merged table keeps
--- the historical full-replacement behavior so clearing a key remains possible.
---@param values table|nil
function M.save(values)
    initialize()
    local replacement = values == nil or values == _merged
    saveMerged(values or _merged or buildMerged(), replacement)
    refreshMerged()
end

--- Explicitly replace all functional settings; missing keys are removed.
---@param values table
function M.replace(values)
    initialize()
    saveMerged(values or {}, true)
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

--- 取某个源的独立配置表（可直接就地修改，改完调 saveSource 落盘）。
---@param id string|nil 省略时用当前活跃源
---@return table
function M.getSource(id)
    initialize()
    return openFile(Paths.sourcePath(id or M.activeSourceId())).data
end

--- 落盘某个源的配置。
--- 传入的表若不是 getSource 返回的那张，则整体 reset 覆盖（未出现的键被丢弃）。
---@param id string|nil 省略时用当前活跃源
---@param values table|nil nil 表示只 flush 现有内容
function M.saveSource(id, values)
    initialize()
    local file = openFile(Paths.sourcePath(id or M.activeSourceId()))
    if type(values) == "table" and values ~= file.data then file:reset(values) end
    file:flush()
end

--- 当前活跃源 id；未配置时为 "local"。
---@return string
function M.activeSourceId()
    return M.get("common").active_source or "local"
end

--- 取设备标识，没有就生成一个并立即落盘。
--- 存在 KOReader 全局设置而非本插件配置里：多源共用同一设备身份，且卸载插件后仍稳定。
---@return string
function M.ensureDeviceId()
    local id = G_reader_settings:readSetting("device_id")
    if type(id) == "string" and id ~= "" then return id end
    -- 随机段必须来自 urandom：math.random 未播种时 LuaJIT 每次启动都是同一序列，
    -- 同一天开机的两台设备会拿到完全相同的 device_id，云端按设备隔离的数据会互相踩。
    local rand
    local f = io.open("/dev/urandom", "rb")
    if f then
        rand = f:read(4)
        f:close()
    end
    if type(rand) == "string" and #rand == 4 then
        rand = rand:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
    else
        math.randomseed(os.time() + tonumber(tostring({}):match("0x(%x+)") or "0", 16))
        rand = string.format("%08x", math.floor(math.random() * 0xffffffff))
    end
    id = string.format("book-%s%08x", rand, os.time() % 0xffffffff)
    G_reader_settings:saveSetting("device_id", id)
    return id
end

return M
