--[[--
阅读页悬浮面板（底部大面板）
  详情 · 常用排版调节 · 目录/更多/首页/关闭

常用项对齐 KOReader 底部条：字体、字号、行距、字重、对比度、
左右/上下边距、分页/滚动；其余通过「更多」进系统配置条。

@module koplugin.book.readermenu
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local ScrollableContainer
do
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    if ok then ScrollableContainer = mod end
end

local WEIGHT_STEPS = { -1, -0.5, 0, 0.5, 1, 1.5, 3 }
local GAMMA_STEPS = { 10, 15, 25, 30, 36, 43, 49, 56 }
local LINE_MIN, LINE_MAX, LINE_STEP = 50, 200, 5
local FONT_MIN, FONT_MAX, FONT_STEP = 12, 255, 1

-- 左右边距预设 {left, right}；优先读 G_defaults
local H_MARGINS = {
    { 5, 5 }, { 10, 10 }, { 15, 15 }, { 20, 20 }, { 30, 30 },
    { 50, 50 }, { 70, 70 }, { 100, 100 }, { 140, 140 },
}
local V_MARGINS = { 5, 10, 15, 20, 30, 50, 70, 100, 140 }
do
    local keys_h = {
        "DCREREADER_CONFIG_H_MARGIN_SIZES_SMALL",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_MEDIUM",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_LARGE",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_X_LARGE",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_XX_LARGE",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_XXX_LARGE",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_HUGE",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_X_HUGE",
        "DCREREADER_CONFIG_H_MARGIN_SIZES_XX_HUGE",
    }
    local keys_v = {
        "DCREREADER_CONFIG_T_MARGIN_SIZES_SMALL",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_MEDIUM",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_LARGE",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_X_LARGE",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_XX_LARGE",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_XXX_LARGE",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_HUGE",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_X_HUGE",
        "DCREREADER_CONFIG_T_MARGIN_SIZES_XX_HUGE",
    }
    local list_h, list_v = {}, {}
    for _, k in ipairs(keys_h) do
        local ok, v = pcall(function() return G_defaults:readSetting(k) end)
        if ok and type(v) == "table" then table.insert(list_h, v) end
    end
    for _, k in ipairs(keys_v) do
        local ok, v = pcall(function() return G_defaults:readSetting(k) end)
        if ok and type(v) == "number" then table.insert(list_v, v) end
    end
    if #list_h > 0 then H_MARGINS = list_h end
    if #list_v > 0 then V_MARGINS = list_v end
end

local function pluginIconDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("(.*/)")
        if dir then return dir .. "icons/" end
    end
    return "icons/"
end

local function loadIcon(name, size)
    size = size or UI.iconSz()
    local ok, img = pcall(function()
        return ImageWidget:new{
            file = pluginIconDir() .. name,
            width = size,
            height = size,
            alpha = true,
        }
    end)
    if ok and img then return img end
    return TextWidget:new{
        text = "·",
        face = UI.face("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

local function nearestIndex(list, value, cmp)
    local best, best_d = 1, math.huge
    for i, v in ipairs(list) do
        local d = cmp and cmp(v, value) or math.abs((tonumber(v) or 0) - (tonumber(value) or 0))
        if d < best_d then best, best_d = i, d end
    end
    return best
end

local function stepList(list, value, delta, cmp)
    local i = nearestIndex(list, value, cmp)
    return list[math.max(1, math.min(#list, i + delta))]
end

local function stepNum(value, delta, min_v, max_v, step)
    local v = (tonumber(value) or 0) + delta * step
    if v < min_v then v = min_v end
    if v > max_v then v = max_v end
    return v
end

local function hMarginCmp(a, b)
    local al = type(a) == "table" and (tonumber(a[1]) or 0) or 0
    local bl = type(b) == "table" and (tonumber(b[1]) or 0) or tonumber(b) or 0
    return math.abs(al - bl)
end

local function formatWeight(v)
    v = tonumber(v) or 0
    if v == 0 then return "0" end
    if v == math.floor(v) then return string.format("%+d", v) end
    return string.format("%+.1f", v)
end

local function formatGamma(v)
    local labels = {
        [10] = "0.8", [15] = "1.0", [25] = "1.45", [30] = "1.9",
        [36] = "2.5", [43] = "4", [49] = "8", [56] = "15",
    }
    local n = tonumber(v) or 15
    return labels[n] or tostring(n)
end

--- 包装字体菜单：选中叶子项后关闭菜单并回调（回到悬浮面板）
local function wrapFontItemTable(items, on_pick)
    if type(items) ~= "table" then
        return items
    end
    local out = {}
    for k, v in pairs(items) do
        if type(k) ~= "number" then
            out[k] = v
        end
    end
    for i, item in ipairs(items) do
        if type(item) ~= "table" then
            out[i] = item
        else
            local copy = {}
            for k, v in pairs(item) do
                copy[k] = v
            end
            if copy.sub_item_table then
                copy.sub_item_table = wrapFontItemTable(copy.sub_item_table, on_pick)
            elseif type(copy.sub_item_table_func) == "function" then
                local orig_func = copy.sub_item_table_func
                copy.sub_item_table_func = function(...)
                    return wrapFontItemTable(orig_func(...) or {}, on_pick)
                end
            elseif type(copy.callback) == "function" then
                local orig = copy.callback
                copy.callback = function(...)
                    local ret = orig(...)
                    if on_pick then on_pick() end
                    return ret
                end
            end
            out[i] = copy
        end
    end
    return out
end

--- on_done: 字体菜单关闭后回调（用于重新打开悬浮面板）
local function showFontSettings(ui, on_done)
    if not ui then
        if on_done then on_done() end
        return
    end
    local font = ui.font
    if font then
        if not font.face_table and font.setupFaceMenuTable then
            pcall(function() font:setupFaceMenuTable() end)
        end
        local items = font.face_table
        if type(items) == "table" then
            if items.needs_refresh and items.refresh_func then
                pcall(items.refresh_func)
                items = font.face_table
            end
            if type(items) == "table" and #items > 0 then
                local font_menu
                local finished = false
                local function finish()
                    if finished then return end
                    finished = true
                    if font_menu then
                        UIManager:close(font_menu)
                        font_menu = nil
                    end
                    if on_done then
                        UIManager:nextTick(on_done)
                    end
                end
                font_menu = Menu:new{
                    title = _("字体"),
                    item_table = wrapFontItemTable(items, finish),
                    is_borderless = true,
                    is_popout = false,
                    covers_fullscreen = true,
                    items_font_size = UI.menuFontSize(),
                    close_callback = function()
                        if finished then return end
                        finished = true
                        font_menu = nil
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                }
                UIManager:show(font_menu)
                return
            end
        end
    end
    if ui.menu and ui.menu.onShowMenu then
        ui.menu:onShowMenu(2)
        return
    end
    ui:handleEvent(Event:new("ShowConfigMenu"))
    if on_done then
        UIManager:nextTick(on_done)
    end
end

--- 悬浮层书目信息只信 API 缓存；本地文件名仅作书名最后兜底
local function apiBookMeta(plugin)
    if plugin and plugin.getCachedBookMeta then
        return plugin:getCachedBookMeta() or {}
    end
    return {}
end

local function bookTitle(plugin, ui)
    local meta = apiBookMeta(plugin)
    if meta.bookName and meta.bookName ~= "" then
        return meta.bookName
    end
    if meta.filename and meta.filename ~= "" then
        return meta.filename
    end
    local file = ui and ui.document and ui.document.file or ""
    return file:match("([^/\\]+)$") or file or _("未知书籍")
end

local function bookAuthor(plugin)
    local a = apiBookMeta(plugin).author or ""
    if type(a) == "table" then a = table.concat(a, ", ") end
    return tostring(a)
end

local function bookSeries(plugin)
    return tostring(apiBookMeta(plugin).series or "")
end

local function bookFavorite(plugin)
    return tostring(apiBookMeta(plugin).favorite or "")
end

local function bookCategory(plugin)
    local k = apiBookMeta(plugin).category or ""
    if type(k) == "table" then k = table.concat(k, " · ") end
    return tostring(k):gsub("\n+", " · ")
end

local function bookDescription(plugin)
    local meta = apiBookMeta(plugin)
    return tostring(meta.description or meta.intro or meta.summary or "")
end

local function currentPageText(ui, plugin)
    local pct = 0
    if plugin and plugin.currentFraction then
        pct = math.floor((plugin:currentFraction() or 0) * 100 + 0.5)
    end
    if ui and ui.getCurrentPage and ui.document and ui.document.getPageCount then
        local page = ui:getCurrentPage()
        local total = ui.document:getPageCount()
        if page and total and total > 0 then
            return T(_("第 %1 / %2 页 · %3%"), page, total, pct), pct
        end
    end
    return string.format("%d%%", pct), pct
end

local function tappable(w, h, on_tap)
    local tap = InputContainer:new{ dimen = Geom:new{ w = w, h = h } }
    tap.ges_events = {
        TapFloat = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap.dimen end,
            },
        },
    }
    tap.onTapFloat = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

local function metaRow(label, value, width)
    if not value or value == "" then return nil end
    local face = UI.face("xx_smallinfofont", 12)
    local label_w = UI.sz(44)
    local value_w = math.max(UI.sz(32), width - label_w - UI.sz(2))
    local label_tw = TextWidget:new{
        text = label,
        face = face,
        fgcolor = UI.muted(),
    }
    local value_tw = TextWidget:new{
        text = tostring(value),
        face = face,
        max_width = value_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local h = math.max(label_tw:getSize().h, value_tw:getSize().h)
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = label_w, h = h },
            label_tw,
        },
        value_tw,
    }
end

local function sectionGap()
    return VerticalSpan:new{ width = UI.sz(16) }
end

local function isPageView(cfg)
    local v = cfg and cfg.view_mode
    if v == "scroll" or v == 1 then return false end
    return true
end

local ReaderFloatMenu = InputContainer:extend{
    name = "book_reader_float_menu",
    covers_fullscreen = false,
    plugin = nil,
}

function ReaderFloatMenu:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:rebuild()
end

function ReaderFloatMenu:getSize()
    return self.dimen
end

function ReaderFloatMenu:onClose()
    self._closed = true
    local region = self._panel_dimen
    UIManager:close(self)
    if region then
        UIManager:setDirty("all", "ui", region)
    else
        UIManager:setDirty("all", "ui")
    end
    if self.close_callback then self.close_callback() end
    return true
end

function ReaderFloatMenu:onCloseWidget()
    self._closed = true
end

function ReaderFloatMenu:refreshPanel()
    if self._closed then return end
    self:rebuild()
    UIManager:setDirty(self, "ui", self._panel_dimen)
end

--- 对齐 ConfigDialog：先写 configurable，再发事件（边距事件本身不回写配置）
function ReaderFloatMenu:applyCreOption(name, value, event_name)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not ui.document.configurable then
        return
    end
    local cfg = ui.document.configurable
    if type(value) == "table" then
        -- 禁止把预设表引用写进 configurable（避免污染 G_defaults 表）
        local copy = {}
        for i, v in ipairs(value) do
            copy[i] = v
        end
        value = copy
    end
    cfg[name] = value
    ui:handleEvent(Event:new("ConfigChange", name, value))
    if event_name then
        -- typeset 边距依赖 unscaled_margins；异常时从 configurable 重建
        local typeset = ui.typeset
        if typeset and not typeset.unscaled_margins then
            local hm = cfg.h_page_margins or { 10, 10 }
            typeset.unscaled_margins = {
                tonumber(hm[1]) or 10,
                tonumber(cfg.t_page_margin) or 10,
                tonumber(hm[2]) or 10,
                tonumber(cfg.b_page_margin) or 10,
            }
        end
        ui:handleEvent(Event:new(event_name, value))
    end
    self:refreshPanel()
    UIManager:setDirty("all", "partial")
end

function ReaderFloatMenu:applyCre(event_name, value)
    local ui = self.plugin and self.plugin.ui
    if not ui then return end
    ui:handleEvent(Event:new(event_name, value))
    self:refreshPanel()
    UIManager:setDirty("all", "partial")
end

function ReaderFloatMenu:applyCreBatch(events)
    local ui = self.plugin and self.plugin.ui
    if not ui then return end
    for _, ev in ipairs(events) do
        ui:handleEvent(Event:new(ev[1], ev[2]))
    end
    self:refreshPanel()
    UIManager:setDirty("all", "partial")
end

--- 左右边距：写 h_page_margins + SetPageHorizMargins
function ReaderFloatMenu:applyHorizMargins(delta)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not ui.document.configurable then
        return
    end
    local cfg = ui.document.configurable
    local cur = cfg.h_page_margins or { 10, 10 }
    local next_v = stepList(H_MARGINS, cur, delta, hMarginCmp)
    self:applyCreOption("h_page_margins", next_v, "SetPageHorizMargins")
end

--- 上下边距：同步写 t/b，再发事件真正改排版
function ReaderFloatMenu:applyVertMargins(delta)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not ui.document.configurable then
        return
    end
    local cfg = ui.document.configurable
    local cur = tonumber(cfg.t_page_margin) or tonumber(cfg.b_page_margin) or 10
    local next_v = stepList(V_MARGINS, cur, delta)
    cfg.t_page_margin = next_v
    cfg.b_page_margin = next_v
    ui:handleEvent(Event:new("ConfigChange", "t_page_margin", next_v))
    ui:handleEvent(Event:new("ConfigChange", "b_page_margin", next_v))
    local typeset = ui.typeset
    if typeset and not typeset.unscaled_margins then
        local hm = cfg.h_page_margins or { 10, 10 }
        typeset.unscaled_margins = {
            tonumber(hm[1]) or 10,
            next_v,
            tonumber(hm[2]) or 10,
            next_v,
        }
    end
    if typeset and typeset.onSetPageTopAndBottomMargin then
        ui:handleEvent(Event:new("SetPageTopAndBottomMargin", { next_v, next_v }))
    else
        ui:handleEvent(Event:new("SetPageTopMargin", next_v))
        ui:handleEvent(Event:new("SetPageBottomMargin", next_v))
    end
    self:refreshPanel()
    UIManager:setDirty("all", "partial")
end

function ReaderFloatMenu:hasCreControls()
    local ui = self.plugin and self.plugin.ui
    return ui and ui.font and ui.document and ui.document.configurable
        and not ui.document.koptinterface
end

--- 全宽步进行：图标 · 标签 · 数值 · −/+，无行框，只留按钮细边
function ReaderFloatMenu:buildStepRow(width, icon_name, label, value_text, on_minus, on_plus)
    local pad_x = UI.sz(4)
    local pad_y = UI.sz(8)
    local row_h = UI.sz(52)
    local btn_w = UI.sz(40)
    local btn_h = UI.sz(36)
    local icon_sz = UI.sz(20)
    local icon_col = icon_sz + UI.sz(4)
    local label_w = UI.sz(88)
    local value_w = UI.sz(72)
    local gap = UI.sz(8)
    local inner_h = row_h - pad_y * 2

    local minus = Button:new{
        text = "−",
        text_font_size = UI.fontSize(20),
        bordersize = UI.line(),
        margin = 0,
        padding = 0,
        width = btn_w,
        height = btn_h,
        callback = on_minus,
        show_parent = self,
    }
    local plus = Button:new{
        text = "+",
        text_font_size = UI.fontSize(20),
        bordersize = UI.line(),
        margin = 0,
        padding = 0,
        width = btn_w,
        height = btn_h,
        callback = on_plus,
        show_parent = self,
    }

    local used = icon_col + gap + label_w + gap + value_w + gap + btn_w + gap + btn_w
    local spacer = math.max(UI.sz(4), width - pad_x * 2 - used)

    local inner = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = icon_col, h = inner_h },
            loadIcon(icon_name, icon_sz),
        },
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{
            dimen = Geom:new{ w = label_w, h = inner_h },
            TextWidget:new{
                text = label,
                face = UI.face("cfont", 15),
                max_width = label_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
        HorizontalSpan:new{ width = spacer },
        CenterContainer:new{
            dimen = Geom:new{ w = value_w, h = inner_h },
            TextWidget:new{
                text = value_text,
                face = UI.face("cfont", 16),
                max_width = value_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
        HorizontalSpan:new{ width = gap },
        minus,
        HorizontalSpan:new{ width = gap },
        plus,
    }

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = row_h },
        inner,
    }
end

function ReaderFloatMenu:buildFontRow(width, face_name, on_tap)
    local pad_x = UI.sz(4)
    local pad_y = UI.sz(10)
    local row_h = UI.sz(48)
    local icon_w = UI.sz(28)
    local chev_w = UI.sz(18)
    local label_w = math.max(UI.sz(40), width - pad_x * 2 - icon_w - UI.sz(8) - chev_w)
    local inner = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = icon_w, h = row_h - pad_y * 2 },
            loadIcon("font.svg", UI.sz(20)),
        },
        HorizontalSpan:new{ width = UI.sz(8) },
        LeftContainer:new{
            dimen = Geom:new{ w = label_w, h = row_h - pad_y * 2 },
            TextWidget:new{
                text = T(_("字体  %1"), face_name or _("默认")),
                face = UI.face("cfont", 15),
                max_width = label_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = chev_w, h = row_h - pad_y * 2 },
            TextWidget:new{
                text = "›",
                face = UI.face("cfont", 20),
                fgcolor = UI.muted(),
            },
        },
    }
    local tap = tappable(width, row_h, on_tap)
    tap[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = row_h },
        inner,
    }
    return tap
end

function ReaderFloatMenu:buildViewToggle(width, is_page, on_page, on_scroll)
    local gap = UI.sz(12)
    local icon_slot = UI.sz(32)
    local btn_w = math.floor((width - icon_slot - gap) / 2)
    local btn_h = UI.sz(40)
    local function chip(text, active, cb)
        return Button:new{
            text = text,
            text_font_size = UI.fontSize(15),
            text_font_bold = active,
            -- 未选中无框，选中只留细线
            bordersize = active and UI.line() or 0,
            margin = 0,
            padding = UI.sz(6),
            width = btn_w,
            height = btn_h,
            callback = cb,
            show_parent = self,
        }
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = width, h = btn_h },
        HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = icon_slot, h = btn_h },
                loadIcon("view.svg", UI.sz(18)),
            },
            chip(_("分页"), is_page, on_page),
            HorizontalSpan:new{ width = gap },
            chip(_("滚动"), not is_page, on_scroll),
        },
    }
end

function ReaderFloatMenu:buildActionCell(cell_w, icon_name, text, callback)
    local h = UI.iconSz() + UI.sz(26)
    local tap = tappable(cell_w, h, callback)
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = h },
        VerticalGroup:new{
            align = "center",
            loadIcon(icon_name, UI.iconSz()),
            VerticalSpan:new{ width = UI.sz(3) },
            TextWidget:new{
                text = text,
                face = UI.face("xx_smallinfofont", 12),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    }
    return tap, h
end

function ReaderFloatMenu:buildDetail(content_w)
    local plugin = self.plugin
    local ui = plugin and plugin.ui
    local title = bookTitle(plugin, ui)
    local author = bookAuthor(plugin)
    local series = bookSeries(plugin)
    local favorite = bookFavorite(plugin)
    local category = bookCategory(plugin)
    local desc = bookDescription(plugin)
    local page_text, pct = currentPageText(ui, plugin)
    local filename = plugin and plugin.remoteFilenameForCurrent and plugin:remoteFilenameForCurrent()

    -- 封面略放大，右侧元信息有更多等高空间；保持约 2:3
    local cw, ch = UI.sz(84), UI.sz(126)
    local path = Cover.cachedPath(plugin, filename)
    local cover_w = Cover.widget(path, cw, ch, title)
    if not path and filename and plugin and plugin.getApi then
        Cover.ensureAsync(plugin:getApi(), plugin, filename, nil)
    end

    local info_w = math.max(UI.sz(40), content_w - cw - UI.sz(10))
    local row_gap = math.max(1, UI.sz(1))
    local bar_gap = UI.sz(3)
    local progress = UI.progressBar(info_w, UI.sz(6), pct)
    local progress_h = progress:getSize().h

    local title_tw = TextWidget:new{
        text = title,
        face = UI.face("cfont", 15),
        max_width = info_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- 优先级：作者 > 进度文案 > 分类 > 标签 > 系列；装不下就丢后面的
    local candidates = {
        metaRow(_("作者"), author ~= "" and author or _("未知作者"), info_w),
        metaRow(_("进度"), page_text, info_w),
        metaRow(_("分类"), favorite, info_w),
        metaRow(_("标签"), category, info_w),
        metaRow(_("系列"), series, info_w),
    }

    local kids = { align = "left", title_tw }
    local used = title_tw:getSize().h
    local reserve = bar_gap + progress_h
    for _, row in ipairs(candidates) do
        if row then
            local rh = row:getSize().h
            local need = row_gap + rh
            if used + need + reserve <= ch then
                table.insert(kids, VerticalSpan:new{ width = row_gap })
                table.insert(kids, row)
                used = used + need
            end
        end
    end
    table.insert(kids, VerticalSpan:new{ width = bar_gap })
    table.insert(kids, progress)

    local info_col = VerticalGroup:new(kids)
    -- 右栏高度锁死封面高，禁止撑破横向头图区
    local col = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "top",
            cover_w,
            HorizontalSpan:new{ width = UI.sz(10) },
            LeftContainer:new{
                dimen = Geom:new{ w = info_w, h = ch },
                info_col,
            },
        },
    }
    if desc ~= "" then
        table.insert(col, VerticalSpan:new{ width = UI.sz(6) })
        table.insert(col, TextBoxWidget:new{
            text = desc,
            face = UI.face("xx_smallinfofont", 12),
            width = content_w,
            height = UI.sz(40),
            alignment = "left",
            fgcolor = UI.muted(),
        })
    end
    return col
end

function ReaderFloatMenu:buildControls(content_w)
    local ui = self.plugin and self.plugin.ui
    if not self:hasCreControls() then
        return nil
    end
    local cfg = ui.document.configurable
    local face = (ui.font and ui.font.font_face) or _("默认")
    local size = tonumber(cfg.font_size) or 22
    local spacing = tonumber(cfg.line_spacing) or 100
    local weight = tonumber(cfg.font_base_weight) or 0
    local gamma = tonumber(cfg.font_gamma) or 15
    local h_margins = cfg.h_page_margins or { 10, 10 }
    local t_margin = tonumber(cfg.t_page_margin) or 10
    local page_mode = isPageView(cfg)

    local row_gap = UI.sz(6)
    local menu = self
    local col = VerticalGroup:new{ align = "left" }
    local first = true
    local function add(row)
        if not first then
            table.insert(col, VerticalSpan:new{ width = row_gap })
        end
        first = false
        table.insert(col, row)
    end

    -- 字体：选完后关字体页并重新打开本悬浮面板
    add(self:buildFontRow(content_w, face, function()
        local plugin = menu.plugin
        menu:onClose()
        UIManager:nextTick(function()
            showFontSettings(ui, function()
                if plugin and plugin.onTapBookReaderFloatMenu then
                    plugin:onTapBookReaderFloatMenu()
                end
            end)
        end)
    end))

    add(self:buildViewToggle(content_w, page_mode,
        function()
            if not page_mode then menu:applyCre("SetViewMode", "page") end
        end,
        function()
            if page_mode then menu:applyCre("SetViewMode", "scroll") end
        end))

    add(self:buildStepRow(content_w, "font_size.svg", _("字号"), string.format("%g", size),
        function() menu:applyCre("SetFontSize", stepNum(size, -1, FONT_MIN, FONT_MAX, FONT_STEP)) end,
        function() menu:applyCre("SetFontSize", stepNum(size, 1, FONT_MIN, FONT_MAX, FONT_STEP)) end))

    add(self:buildStepRow(content_w, "line_spacing.svg", _("行距"), string.format("%d%%", spacing),
        function() menu:applyCre("SetLineSpace", stepNum(spacing, -1, LINE_MIN, LINE_MAX, LINE_STEP)) end,
        function() menu:applyCre("SetLineSpace", stepNum(spacing, 1, LINE_MIN, LINE_MAX, LINE_STEP)) end))

    add(self:buildStepRow(content_w, "font_weight.svg", _("字重"), formatWeight(weight),
        function() menu:applyCre("SetFontBaseWeight", stepList(WEIGHT_STEPS, weight, -1)) end,
        function() menu:applyCre("SetFontBaseWeight", stepList(WEIGHT_STEPS, weight, 1)) end))

    add(self:buildStepRow(content_w, "contrast.svg", _("对比度"), formatGamma(gamma),
        function() menu:applyCre("SetFontGamma", stepList(GAMMA_STEPS, gamma, -1)) end,
        function() menu:applyCre("SetFontGamma", stepList(GAMMA_STEPS, gamma, 1)) end))

    local h_val = tonumber(h_margins[1]) or 10
    add(self:buildStepRow(content_w, "margin.svg", _("左右边距"), tostring(h_val),
        function() menu:applyHorizMargins(-1) end,
        function() menu:applyHorizMargins(1) end))

    add(self:buildStepRow(content_w, "margin.svg", _("上下边距"), tostring(t_margin),
        function() menu:applyVertMargins(-1) end,
        function() menu:applyVertMargins(1) end))

    return col
end

function ReaderFloatMenu:buildActions(content_w)
    local plugin = self.plugin
    local ui = plugin and plugin.ui
    local n = 4
    local cell_w = math.floor(content_w / n)
    local menu = self
    local items = {
        { "toc.svg", _("目录"), function()
            menu:onClose()
            UIManager:nextTick(function()
                if ui and ui.toc and ui.toc.onShowToc then ui.toc:onShowToc() end
            end)
        end },
        { "more.svg", _("更多"), function()
            menu:onClose()
            UIManager:nextTick(function()
                if ui then ui:handleEvent(Event:new("ShowConfigMenu")) end
            end)
        end },
        { "home.svg", _("首页"), function()
            menu:onClose()
            UIManager:nextTick(function()
                if plugin and plugin.exitReadingToDesktop then
                    plugin:exitReadingToDesktop()
                end
            end)
        end },
        { "close.svg", _("关闭"), function() menu:onClose() end },
    }
    local row = HorizontalGroup:new{}
    local h = 0
    for _, it in ipairs(items) do
        local cell, ch = self:buildActionCell(cell_w, it[1], it[2], it[3])
        table.insert(row, cell)
        if ch > h then h = ch end
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = Geom:new{ w = content_w, h = h },
        row,
    }, h
end

function ReaderFloatMenu:rebuild()
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.sz(14)
    local panel_w = w - pad * 2
    local sb_gutter = 0
    if ScrollableContainer then
        if ScrollableContainer.getScrollbarWidth then
            sb_gutter = ScrollableContainer:getScrollbarWidth()
        else
            sb_gutter = 3 * Screen:scaleBySize(6)
        end
    end
    local viewport_w = math.max(UI.sz(120), panel_w - pad * 2)
    local content_w = math.max(UI.sz(100), viewport_w - sb_gutter)
    local max_h = math.floor(h * 0.88)

    local detail = self:buildDetail(content_w)
    local controls = self:buildControls(content_w)
    local actions = self:buildActions(content_w)

    local body_kids = { align = "left", detail }
    table.insert(body_kids, sectionGap())

    if controls then
        table.insert(body_kids, TextWidget:new{
            text = _("阅读设置"),
            face = UI.face("cfont", 14),
            fgcolor = UI.muted(),
        })
        table.insert(body_kids, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(body_kids, controls)
        table.insert(body_kids, sectionGap())
    else
        -- PDF：无 CRE 控件，给系统配置入口
        local tap = tappable(content_w, UI.sz(48), function()
            self:onClose()
            UIManager:nextTick(function()
                local ui = self.plugin and self.plugin.ui
                if ui then ui:handleEvent(Event:new("ShowConfigMenu")) end
            end)
        end)
        tap[1] = FrameContainer:new{
            bordersize = 0,
            padding = UI.sz(10),
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = content_w, h = UI.sz(48) },
            HorizontalGroup:new{
                align = "center",
                loadIcon("more.svg", UI.sz(20)),
                HorizontalSpan:new{ width = UI.sz(8) },
                TextWidget:new{
                    text = _("排版与显示设置"),
                    face = UI.face("cfont", 15),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            },
        }
        table.insert(body_kids, tap)
        table.insert(body_kids, sectionGap())
    end

    table.insert(body_kids, actions)

    local body = VerticalGroup:new(body_kids)
    local body_h = body:getSize().h
    local panel_h = math.min(max_h, body_h + pad * 2)
    local scroll_h = panel_h - pad * 2
    local content, inner_h

    if ScrollableContainer and body_h > scroll_h then
        self.cropping_widget = ScrollableContainer:new{
            dimen = Geom:new{ w = viewport_w, h = scroll_h },
            show_parent = self,
            LeftContainer:new{
                dimen = Geom:new{ w = content_w, h = body_h },
                body,
            },
        }
        content = self.cropping_widget
        inner_h = scroll_h
    else
        self.cropping_widget = nil
        content = body
        panel_h = body_h + pad * 2
        inner_h = body_h
    end

    local panel = FrameContainer:new{
        bordersize = UI.line(),
        color = UI.rule(),
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = panel_w, h = panel_h },
        LeftContainer:new{
            dimen = Geom:new{ w = viewport_w, h = inner_h },
            content,
        },
    }

    local panel_x = math.floor((w - panel_w) / 2)
    -- 底部留白加大，避免贴底；垂直略偏下但仍居中感
    local bottom_gap = UI.sz(56)
    local top_gap = UI.sz(24)
    local panel_y = h - panel_h - bottom_gap
    if panel_y < top_gap then
        panel_y = top_gap
    end
    -- 若高度有余，再往上抬一点（整体垂直居中偏下）
    local slack = h - panel_h - bottom_gap - top_gap
    if slack > 0 then
        panel_y = top_gap + math.floor(slack * 0.35)
    end
    self._panel_dimen = Geom:new{ x = panel_x, y = panel_y, w = panel_w, h = panel_h }
    panel.overlap_offset = { panel_x, panel_y }

    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        panel,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

return ReaderFloatMenu
