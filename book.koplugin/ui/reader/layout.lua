--[[--
阅读风格预设：纸书 / 专栏 / 散文 / 起首。

点选后立刻套到当前可重排文档，并写入全局默认（copt_* + style tweaks +
styletweaks/book_layout.css）。当前书用 book_style_tweak，避免与全局 CSS 文件叠两遍。

@module koplugin.book.ui.reader.layout
--]]

require("l10n").apply()
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local util = require("util")
local Settings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Layout = {}

local CSS_FILE_NAME = "book_layout.css"
local CSS_TWEAK_ID = CSS_FILE_NAME

--- 本模块托管的内置 style tweak id（切换时清理；不碰脚注等系统默认项）
local MANAGED_TWEAK_IDS = {
    "margin_body_0",
    "font_size_most_reset",
    "lineheight_all_inherit",
    "cjk_tailored",
    "text_align_most_justify",
    "paragraph_first_no_indent",
    CSS_TWEAK_ID,
}

local CSS_DISABLE_DROP_CAP = [[
*::first-letter { float: none !important; font-size: inherit !important; }
]]

local PRESETS = {
    {
        id = "book",
        title = _("纸书"),
        summary = _("章题居中 · 缩进连排"),
        font_size = 22,
        line_spacing = 150,
        font_base_weight = 0,
        h_margins = { 18, 18 },
        t_margin = 14,
        b_margin = 14,
        tweaks = {
            "margin_body_0",
            "font_size_most_reset",
            "lineheight_all_inherit",
            "cjk_tailored",
            "text_align_most_justify",
        },
        css = CSS_DISABLE_DROP_CAP .. [[
h1, h2, h3 {
  text-align: center !important;
  text-indent: 0 !important;
  margin-top: 1.3em !important;
  margin-bottom: 0.6em !important;
}
p, li {
  text-indent: 2em !important;
  margin-top: 0 !important;
  margin-bottom: 0.25em !important;
  text-align: justify !important;
}
]],
    },
    {
        id = "column",
        title = _("专栏"),
        summary = _("宽留白 · 短行"),
        font_size = 22,
        line_spacing = 145,
        font_base_weight = 0,
        h_margins = { 42, 42 },
        t_margin = 14,
        b_margin = 14,
        tweaks = {
            "margin_body_0",
            "font_size_most_reset",
            "lineheight_all_inherit",
            "cjk_tailored",
            "text_align_most_justify",
        },
        css = CSS_DISABLE_DROP_CAP .. [[
h1, h2, h3 {
  text-align: left !important;
  text-indent: 0 !important;
  margin-top: 1.1em !important;
  margin-bottom: 0.5em !important;
}
p, li {
  text-indent: 2em !important;
  margin-top: 0 !important;
  margin-bottom: 0 !important;
  text-align: justify !important;
}
]],
    },
    {
        id = "essay",
        title = _("散文"),
        summary = _("无缩进 · 段间留白"),
        font_size = 22,
        line_spacing = 170,
        font_base_weight = 0,
        h_margins = { 28, 28 },
        t_margin = 22,
        b_margin = 22,
        tweaks = {
            "margin_body_0",
            "font_size_most_reset",
            "lineheight_all_inherit",
            "cjk_tailored",
            "text_align_most_justify",
        },
        css = CSS_DISABLE_DROP_CAP .. [[
h1, h2, h3 {
  text-align: center !important;
  text-indent: 0 !important;
  margin-top: 1.8em !important;
  margin-bottom: 0.9em !important;
}
p, li {
  text-indent: 0 !important;
  margin-top: 0 !important;
  margin-bottom: 1.1em !important;
  text-align: justify !important;
}
]],
    },
    {
        id = "initial",
        title = _("起首"),
        summary = _("章首首字下沉"),
        font_size = 22,
        line_spacing = 155,
        font_base_weight = 0,
        h_margins = { 32, 32 },
        t_margin = 18,
        b_margin = 18,
        tweaks = {
            "margin_body_0",
            "font_size_most_reset",
            "lineheight_all_inherit",
            "cjk_tailored",
            "text_align_most_justify",
            "paragraph_first_no_indent",
        },
        css = [[
DocFragment > p:first-of-type,
body > p:first-of-type {
  text-indent: 0 !important;
}
DocFragment > p:first-of-type::first-letter,
body > p:first-of-type::first-letter {
  float: left !important;
  font-size: 2.8em !important;
  line-height: 0.9 !important;
  margin-right: 0.12em !important;
  margin-top: 0.05em !important;
  font-weight: bold !important;
}
h1, h2, h3 {
  text-align: left !important;
  text-indent: 0 !important;
  margin-top: 1.2em !important;
  margin-bottom: 0.5em !important;
}
p, li {
  text-indent: 2em !important;
  margin-top: 0 !important;
  margin-bottom: 0.15em !important;
  text-align: justify !important;
}
]],
    },
}

local PRESETS_BY_ID = {}
for _, preset in ipairs(PRESETS) do
    PRESETS_BY_ID[preset.id] = preset
end

local function managedSet()
    local set = {}
    for _, id in ipairs(MANAGED_TWEAK_IDS) do
        set[id] = true
    end
    return set
end

local function cssPath()
    return DataStorage:getDataDir() .. "/styletweaks/" .. CSS_FILE_NAME
end

local function trimCss(css)
    return (css:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 确保 styletweaks/book_layout.css 存在（Reader 扫描前落盘）。
---@param preset table|nil
---@return nil
function Layout.ensureCssFile(preset)
    if preset == nil then
        preset = Layout.currentPreset()
    end
    local dir = DataStorage:getDataDir() .. "/styletweaks"
    util.makePath(dir)
    local path = cssPath()
    local f = io.open(path, "w")
    if not f then
        return
    end
    if not preset then
        f:write("/* book layout disabled */\n")
    else
        f:write(trimCss(preset.css))
        f:write("\n")
    end
    f:close()
end

---@return table[]
function Layout.presets()
    return PRESETS
end

---@param id string|nil
---@return table|nil
function Layout.get(id)
    return id and PRESETS_BY_ID[id] or nil
end

---@return table|nil
function Layout.currentPreset()
    local settings = Settings.get()
    local id = settings.book_reader_layout_id
    if not id or id == "off" then
        return nil
    end
    return Layout.get(id)
end

---@param ui table|nil
---@return boolean
function Layout.isReflowable(ui)
    return ui ~= nil
        and ui.rolling ~= nil
        and ui.font ~= nil
        and ui.document ~= nil
        and ui.font.configurable ~= nil
end

---@param ui table|nil
---@return string
function Layout.matchId(ui)
    local settings = Settings.get()
    local id = settings.book_reader_layout_id
    if id == "off" or id == nil or id == "" then
        return "off"
    end
    if PRESETS_BY_ID[id] then
        return id
    end
    if not Layout.isReflowable(ui) then
        return "off"
    end
    local config = ui.font.configurable
    for _, preset in ipairs(PRESETS) do
        local h = config.h_page_margins
        if tonumber(config.font_size) == preset.font_size
            and tonumber(config.line_spacing) == preset.line_spacing
            and type(h) == "table"
            and tonumber(h[1]) == preset.h_margins[1]
            and tonumber(h[2]) == preset.h_margins[2]
            and tonumber(config.t_page_margin) == preset.t_margin
            and tonumber(config.b_page_margin) == preset.b_margin
        then
            return preset.id
        end
    end
    return "off"
end

local function clearManaged(tweaks, managed)
    if type(tweaks) ~= "table" then
        return {}
    end
    local out = {}
    for id, enabled in pairs(tweaks) do
        if not managed[id] then
            out[id] = enabled
        end
    end
    return out
end

local function enableTweaks(list, into)
    for _, id in ipairs(list or {}) do
        into[id] = true
    end
end

local function clearCssOverlay(styletweak)
    local managed = managedSet()
    local global = clearManaged(
        (styletweak and styletweak.global_tweaks)
            or G_reader_settings:readSetting("style_tweaks")
            or {},
        managed
    )
    G_reader_settings:saveSetting("style_tweaks", global)
    if styletweak then
        styletweak.global_tweaks = global
        styletweak.doc_tweaks = clearManaged(styletweak.doc_tweaks or {}, managed)
        styletweak.book_style_tweak = nil
        styletweak.book_style_tweak_enabled = false
        if styletweak.updateCssText then
            styletweak:updateCssText(true)
        end
    end
    -- 空文件保留占位，避免残留旧 CSS；且不在 style_tweaks 里启用
    local dir = DataStorage:getDataDir() .. "/styletweaks"
    util.makePath(dir)
    local f = io.open(cssPath(), "w")
    if f then
        f:write("/* book layout disabled */\n")
        f:close()
    end
end

--- 关闭预设：去掉本插件注入的 CSS / 托管 tweak，不改字号边距。
---@param ui table|nil
---@return boolean ok
function Layout.disable(ui)
    clearCssOverlay(ui and ui.styletweak or nil)
    local settings = Settings.get()
    settings.book_reader_layout_id = "off"
    Settings.save(settings)
    if ui and ui.handleEvent then
        ui:handleEvent(Event:new("UpdatePos"))
    end
    local Notification = require("ui/widget/notification")
    Notification:notify(_("已关闭阅读风格预设"))
    return true
end

--- 写入全局默认：copt_* + style_tweaks + CSS 文件。
---@param preset table
---@param styletweak table|nil
---@return nil
function Layout.saveDefaults(preset, styletweak)
    G_reader_settings:saveSetting("copt_font_size", preset.font_size)
    G_reader_settings:saveSetting("copt_line_spacing", preset.line_spacing)
    G_reader_settings:saveSetting("copt_font_base_weight", preset.font_base_weight)
    G_reader_settings:saveSetting("copt_h_page_margins", {
        preset.h_margins[1],
        preset.h_margins[2],
    })
    G_reader_settings:saveSetting("copt_t_page_margin", preset.t_margin)
    G_reader_settings:saveSetting("copt_b_page_margin", preset.b_margin)

    local managed = managedSet()
    local global = clearManaged(
        (styletweak and styletweak.global_tweaks)
            or G_reader_settings:readSetting("style_tweaks")
            or {},
        managed
    )
    enableTweaks(preset.tweaks, global)
    global[CSS_TWEAK_ID] = true
    G_reader_settings:saveSetting("style_tweaks", global)
    if styletweak then
        styletweak.global_tweaks = global
    end

    Layout.ensureCssFile(preset)

    local settings = Settings.get()
    settings.book_reader_layout_id = preset.id
    Settings.save(settings)
end

local function applyTypography(ui, preset)
    local font = ui.font
    local config = font.configurable
    config.font_size = preset.font_size
    ui.document:setFontSize(Screen:scaleBySize(preset.font_size))
    config.line_spacing = preset.line_spacing
    ui.document:setInterlineSpacePercent(preset.line_spacing)
    config.font_base_weight = preset.font_base_weight
    if ui.document.setFontBaseWeight then
        ui.document:setFontBaseWeight(preset.font_base_weight)
    end
    config.h_page_margins = { preset.h_margins[1], preset.h_margins[2] }
    config.t_page_margin = preset.t_margin
    config.b_page_margin = preset.b_margin
    ui:handleEvent(Event:new("SetPageHorizMargins", {
        preset.h_margins[1],
        preset.h_margins[2],
    }))
    ui:handleEvent(Event:new("SetPageTopMargin", preset.t_margin))
    ui:handleEvent(Event:new("SetPageBottomMargin", preset.b_margin))
end

local function applyCss(ui, preset)
    local styletweak = ui.styletweak
    if not styletweak then
        return
    end
    local managed = managedSet()
    local doc = clearManaged(styletweak.doc_tweaks or {}, managed)
    enableTweaks(preset.tweaks, doc)
    -- 当前书用 book_style_tweak，关掉同内容的全局文件，避免叠两遍
    doc[CSS_TWEAK_ID] = false
    styletweak.doc_tweaks = doc
    styletweak.book_style_tweak = trimCss(preset.css)
    styletweak.book_style_tweak_enabled = true
    if styletweak.enabled == false then
        styletweak.enabled = true
    end
    if styletweak.updateCssText then
        styletweak:updateCssText(true)
    end
end

--- 套到当前书并写成全局默认。传 "off" 则关闭预设。
---@param ui table
---@param preset table|string
---@return boolean ok
function Layout.apply(ui, preset)
    if preset == "off" then
        return Layout.disable(ui)
    end
    if type(preset) == "string" then
        preset = Layout.get(preset)
    end
    if not preset then
        return false
    end
    if not Layout.isReflowable(ui) then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("当前文档不支持字体与排版调整"),
        })
        return false
    end

    applyTypography(ui, preset)
    applyCss(ui, preset)
    Layout.saveDefaults(preset, ui.styletweak)
    ui:handleEvent(Event:new("UpdatePos"))

    local Notification = require("ui/widget/notification")
    Notification:notify(T(_("已应用「%1」并设为默认"), preset.title))
    return true
end

--- 弹出阅读风格列表。
---@param ui table|nil
---@return nil
function Layout.showMenu(ui)
    if not Layout.isReflowable(ui) then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("当前文档不支持字体与排版调整"),
        })
        return
    end
    local current = Layout.matchId(ui)
    local Popup = require("ui.components.popup")
    local items = {
        {
            text = _("关闭预设"),
            value = "off",
            mandatory = _("不套用预设样式"),
            checked = current == "off",
        },
    }
    for _, preset in ipairs(PRESETS) do
        items[#items + 1] = {
            text = preset.title,
            value = preset.id,
            mandatory = preset.summary,
            checked = preset.id == current,
        }
    end
    items[#items + 1] = {
        text = _("更多排版…"),
        callback = function()
            ui:handleEvent(Event:new("ShowConfigMenu"))
        end,
    }
    Popup.list{
        title = _("阅读风格"),
        items = items,
        current = current,
        choice_icons = true,
        on_select = function(id)
            Layout.apply(ui, id)
        end,
    }
end

return Layout
