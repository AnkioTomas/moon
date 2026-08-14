--[[--
阅读页悬浮面板（底部大面板）
  详情 · 常用排版调节 · 目录/更多/首页/关闭

常用项对齐 KOReader 底部条：字体、字号、行距、字重、对比度、
左右/上下边距、分页/滚动；其余通过「更多」进系统配置条。

@module koplugin.book.ui.readermenu
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
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Image = require("ui.components.image")
local Pager = require("ui.components.pager")
local Popup = require("ui.components.popup")
local Store = require("book.store")
local Progress = require("book.progress")
local MoonSettings = require("utils.settings")
local Host = require("host")
local BookInfo = require("ui.components.bookinfo")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

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


--- 加载 icons/ 下图标为 Image widget。
---@param name string
---@param size number|nil
---@return table|nil
local function loadIcon(name, size)
    size = size or UI.iconSz()
    return Image.widget{
        src = name,
        width = size,
        height = size,
    }
end

--- 在列表中找与 value 最近的下标。
---@param list table
---@param value any
---@param cmp fun(a: any, b: any): number|nil
---@return number
local function nearestIndex(list, value, cmp)
    local best, best_d = 1, math.huge
    for i, v in ipairs(list) do
        local d = cmp and cmp(v, value) or math.abs((tonumber(v) or 0) - (tonumber(value) or 0))
        if d < best_d then best, best_d = i, d end
    end
    return best
end

--- 按 delta 在预设列表中步进取值。
---@param list table
---@param value any
---@param delta number
---@param cmp fun(a: any, b: any): number|nil
---@return any
local function stepList(list, value, delta, cmp)
    local i = nearestIndex(list, value, cmp)
    return list[math.max(1, math.min(#list, i + delta))]
end

--- 数值步进并夹到 [min_v, max_v]。
---@param value number|nil
---@param delta number
---@param min_v number
---@param max_v number
---@param step number
---@return number
local function stepNum(value, delta, min_v, max_v, step)
    local v = (tonumber(value) or 0) + delta * step
    if v < min_v then v = min_v end
    if v > max_v then v = max_v end
    return v
end

--- 左右边距预设比较：取左缘距离差。
---@param a table|number|nil
---@param b table|number|nil
---@return number
local function hMarginCmp(a, b)
    local al = type(a) == "table" and (tonumber(a[1]) or 0) or 0
    local bl = type(b) == "table" and (tonumber(b[1]) or 0) or tonumber(b) or 0
    return math.abs(al - bl)
end

--- 格式化字重显示文案。
---@param v number|nil
---@return string
local function formatWeight(v)
    v = tonumber(v) or 0
    if v == 0 then return "0" end
    if v == math.floor(v) then return string.format("%+d", v) end
    return string.format("%+.1f", v)
end

--- 格式化对比度（gamma）显示文案。
---@param v number|nil
---@return string
local function formatGamma(v)
    local labels = {
        [10] = "0.8", [15] = "1.0", [25] = "1.45", [30] = "1.9",
        [36] = "2.5", [43] = "4", [49] = "8", [56] = "15",
    }
    local n = tonumber(v) or 15
    return labels[n] or tostring(n)
end

--- 包装字体菜单：选中叶子项后关闭菜单并回调（回到悬浮面板）。
---@param items table
---@param on_pick fun()|nil
---@return table
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

--- 打开字体设置菜单；on_done 在关闭后回调（用于重新打开悬浮面板）。
---@param ui table|nil
---@param on_done fun()|nil
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
                local menu
                local finished = false
                --- 关闭字体菜单并回调 on_done。
                local function finish()
                    if finished then return end
                    finished = true
                    if menu then
                        UIManager:close(menu)
                        menu = nil
                    end
                    if on_done then
                        UIManager:nextTick(on_done)
                    end
                end
                menu = Popup.list{
                    title = _("字体"),
                    raw = true,
                    items = wrapFontItemTable(items, finish),
                    close_callback = function()
                        if finished then return end
                        finished = true
                        menu = nil
                        if on_done then
                            UIManager:nextTick(on_done)
                        end
                    end,
                }
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

--- 悬浮层书目信息只信 API 缓存；本地文件名仅作书名最后兜底。
---@param plugin table|nil
---@return table
local function apiBookMeta(plugin)
    local ui = plugin and plugin.ui
    local file = ui and ui.document and ui.document.file
    if not file then
        return {}
    end
    local id = Store.identityFor(file)
    if id and id.book_key then
        return Store.getMeta(id.book_key) or {}
    end
    local filename = Store.remoteFilename(file)
    if filename then
        return Store.getMeta(filename) or Store.findMeta(filename) or { id = filename }
    end
    return {}
end

--- 取书名：API 元数据优先，否则用文件名。
---@param plugin table|nil
---@param ui table|nil
---@return string
local function bookTitle(plugin, ui)
    local meta = apiBookMeta(plugin)
    if meta.title and meta.title ~= "" then
        return meta.title
    end
    if meta.id and meta.id ~= "" then
        return meta.id
    end
    local file = ui and ui.document and ui.document.file or ""
    return file:match("([^/\\]+)$") or file or _("未知书籍")
end

--- 取作者文案。
---@param plugin table|nil
---@return string
local function bookAuthor(plugin)
    local a = apiBookMeta(plugin).authors or ""
    if type(a) == "table" then a = table.concat(a, ", ") end
    return tostring(a)
end

--- 取系列文案。
---@param plugin table|nil
---@return string
local function bookSeries(plugin)
    return tostring(apiBookMeta(plugin).series or "")
end

--- 取分类（favorite）文案。
---@param plugin table|nil
---@return string
local function bookFavorite(plugin)
    return tostring(apiBookMeta(plugin).favorite or "")
end

--- 取标签（category）文案。
---@param plugin table|nil
---@return string
local function bookCategory(plugin)
    local k = apiBookMeta(plugin).category or ""
    if type(k) == "table" then k = table.concat(k, " · ") end
    return tostring(k):gsub("\n+", " · ")
end

--- 取简介文案。
---@param plugin table|nil
---@return string
local function bookDescription(plugin)
    local meta = apiBookMeta(plugin)
    return tostring(meta.intro or "")
end

--- 当前页码与进度百分比文案。
---@param ui table|nil
---@return string, number
local function currentPageText(ui)
    local pct = math.floor((Progress.fraction(ui) or 0) * 100 + 0.5)
    if ui and ui.getCurrentPage and ui.document and ui.document.getPageCount then
        local page = ui:getCurrentPage()
        local total = ui.document:getPageCount()
        if page and total and total > 0 then
            return T(_("第 %1 / %2 页 · %3%"), page, total, pct), pct
        end
    end
    return string.format("%d%%", pct), pct
end

--- 包一层可点击容器。
---@param w number
---@param h number
---@param on_tap fun()|nil
---@return table
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

--- 元信息一行；值为空返回 nil。
---@param label string
---@param value string|nil
---@param width number
---@return table|nil
local function metaRow(label, value, width)
    if not value or value == "" then return nil end
    local label_w = UI.sz(44)
    local value_w = math.max(UI.sz(32), width - label_w - UI.sz(2))
    local label_tw = TextWidget:new{
        text = label,
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = UI.muted(),
    }
    local value_tw = TextWidget:new{
        text = tostring(value),
        face = UI.face("xx_smallinfofont", 12),
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

--- 区块垂直间距。
---@return table
local function sectionGap()
    return VerticalSpan:new{ width = UI.sz(16) }
end

--- 是否为分页视图（非 scroll）。
---@param cfg table|nil
---@return boolean
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

--- 初始化尺寸、返回键并 rebuild。
function ReaderFloatMenu:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:rebuild()
end

--- 返回悬浮菜单尺寸。
---@return table
function ReaderFloatMenu:getSize()
    return self.dimen
end

--- 关闭悬浮面板并区域刷新。
---@return boolean
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

--- Widget 关闭标记。
function ReaderFloatMenu:onCloseWidget()
    self._closed = true
end

--- 重建面板并局部脏刷新。
function ReaderFloatMenu:refreshPanel()
    if self._closed then return end
    self:rebuild()
    UIManager:setDirty(self, "ui", self._panel_dimen)
end

--- 对齐 ConfigDialog：先写 configurable，再发事件（边距事件本身不回写配置）。
---@param name string
---@param value any
---@param event_name string|nil
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

--- 直接向 Reader 发 CRE 配置事件并刷新面板。
---@param event_name string
---@param value any
function ReaderFloatMenu:applyCre(event_name, value)
    local ui = self.plugin and self.plugin.ui
    if not ui then return end
    ui:handleEvent(Event:new(event_name, value))
    self:refreshPanel()
    UIManager:setDirty("all", "partial")
end

--- 左右边距：写 h_page_margins + SetPageHorizMargins。
---@param delta number
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

--- 上下边距：同步写 t/b，再发事件真正改排版。
---@param delta number
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

--- 当前文档是否支持 CRE 排版控件。
---@return boolean|nil
function ReaderFloatMenu:hasCreControls()
    local ui = self.plugin and self.plugin.ui
    return ui and ui.font and ui.document and ui.document.configurable
        and not ui.document.koptinterface
end

--- 全宽步进行：图标 · 标签 · 数值 · −/+，无行框，只留按钮细边。
---@param width number
---@param icon_name string
---@param label string
---@param value_text string
---@param on_minus fun()
---@param on_plus fun()
---@return table
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

--- 字体选择行（点击打开字体菜单）。
---@param width number
---@param face_name string|nil
---@param on_tap fun()
---@return table
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

--- 分页 / 滚动视图切换条。
---@param width number
---@param is_page boolean
---@param on_page fun()
---@param on_scroll fun()
---@return table
function ReaderFloatMenu:buildViewToggle(width, is_page, on_page, on_scroll)
    local gap = UI.sz(12)
    local icon_slot = UI.sz(32)
    local btn_w = math.floor((width - icon_slot - gap) / 2)
    local btn_h = UI.sz(40)
    --- 构建分页/滚动切换芯片按钮。
    ---@param text string
    ---@param active boolean
    ---@param cb fun()|nil
    ---@return table
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
                loadIcon("reader.svg", UI.sz(18)),
            },
            chip(_("分页"), is_page, on_page),
            HorizontalSpan:new{ width = gap },
            chip(_("滚动"), not is_page, on_scroll),
        },
    }
end

--- 底部动作格：图标 + 文案。
---@param cell_w number
---@param icon_name string
---@param text string
---@param callback fun()|nil
---@return table, number
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

--- 构建详情区（封面 + 元信息 + 简介）。
---@param content_w number
---@return table
function ReaderFloatMenu:buildDetail(content_w)
    local plugin = self.plugin
    local ui = plugin and plugin.ui
    local title = bookTitle(plugin, ui)
    local author = bookAuthor(plugin)
    local series = bookSeries(plugin)
    local favorite = bookFavorite(plugin)
    local category = bookCategory(plugin)
    local desc = bookDescription(plugin)
    local page_text, pct = currentPageText(ui)
    local filename
    local cover_book = {
        title = title,
        percent = pct,
    }
    local file = plugin and plugin.ui and plugin.ui.document and plugin.ui.document.file
    if file then
        filename = Store.remoteFilename(file)
        local id = Store.identityFor(file)
        if id and id.ref then
            cover_book.ref = id.ref
        end
    end

    -- 封面略放大，右侧元信息有更多等高空间；保持约 2:3
    local cw, ch = UI.sz(84), UI.sz(126)
    local source = plugin and plugin.getSource and plugin:getSource() or nil
    local cover_w = select(1, BookInfo.cover(plugin, source, cover_book, cw, ch, {
        show_parent = self,
    }))

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

--- 构建排版控制区；非 CRE 返回 nil。
---@param content_w number
---@return table|nil
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
    --- 向控制列追加一行（自动加间距）。
    ---@param row table
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
                ReaderFloatMenu.onTap(plugin)
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

--- 构建底部动作行（目录/更多/首页等）。
---@param content_w number
---@return table, number
function ReaderFloatMenu:buildActions(content_w)
    local plugin = self.plugin
    local ui = plugin and plugin.ui
    local n = 4
    local cell_w = math.floor(content_w / n)
    local menu = self
    local Chapter = require("book.chapter")
    --- 关闭面板并打开目录。
    local function openToc()
        menu:onClose()
        UIManager:nextTick(function()
            if Chapter.isActive() and Chapter.showTocMenu() then
                return
            end
            if ui and ui.toc and ui.toc.onShowToc then ui.toc:onShowToc() end
        end)
    end
    --- 关闭面板并回 Book 桌面。
    local function goHome()
        menu:onClose()
        UIManager:nextTick(function()
            ReaderFloatMenu.exitToDesktop(plugin)
        end)
    end
    local items
    if Chapter.isActive() then
        items = {
            { "toc.svg", _("目录"), openToc },
            { "margin.svg", _("上一章"), function()
                menu:onClose()
                UIManager:nextTick(function() Chapter.prev() end)
            end },
            { "margin.svg", _("下一章"), function()
                menu:onClose()
                UIManager:nextTick(function() Chapter.next() end)
            end },
            { "home.svg", _("首页"), goHome },
        }
    else
        items = {
            { "toc.svg", _("目录"), openToc },
            { "more.svg", _("更多"), function()
                menu:onClose()
                UIManager:nextTick(function()
                    if ui then ui:handleEvent(Event:new("ShowConfigMenu")) end
                end)
            end },
            { "home.svg", _("首页"), goHome },
            { "close.svg", _("关闭"), function() menu:onClose() end },
        }
    end
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

--- 重建整块悬浮面板并分页。
function ReaderFloatMenu:rebuild()
    pcall(function()
        require("utils.font").applyCurrent()
    end)
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.pagePad()
    local panel_w = w - pad * 2
    local content_w = math.max(UI.sz(100), panel_w - pad * 2)
    local max_h = math.floor(h * 0.88)
    local band_h = Pager.bandH()
    local body_h = math.max(UI.sz(80), max_h - pad * 2 - band_h)

    local detail = self:buildDetail(content_w)
    local controls = self:buildControls(content_w)
    local actions = self:buildActions(content_w)

    local blocks = { detail }
    if controls then
        table.insert(blocks, VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = _("阅读设置"),
                face = UI.face("cfont", 14),
                fgcolor = UI.muted(),
            },
            VerticalSpan:new{ width = UI.sz(8) },
            controls,
        })
    else
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
        table.insert(blocks, tap)
    end
    table.insert(blocks, actions)

    local packed = {}
    for i, block in ipairs(blocks) do
        if i > 1 then
            table.insert(packed, VerticalSpan:new{ width = UI.sz(16) })
        end
        table.insert(packed, block)
    end

    local pages_kids = Pager.pack(packed, body_h)
    local pages = #pages_kids
    local page = Pager.clamp(self._menu_page, pages)
    self._menu_page = page
    self.cropping_widget = nil

    local page_body = LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = body_h },
        VerticalGroup:new(pages_kids[page]),
    }

    local inner = VerticalGroup:new{
        align = "left",
        CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = body_h },
            page_body,
        },
        Pager.band(content_w, page, pages, {
            on_prev = function()
                self._menu_page = page - 1
                self:rebuild()
            end,
            on_next = function()
                self._menu_page = page + 1
                self:rebuild()
            end,
            on_first = function()
                self._menu_page = 1
                self:rebuild()
            end,
            on_last = function()
                self._menu_page = pages
                self:rebuild()
            end,
        }),
    }

    local panel_h = body_h + band_h + pad * 2
    local panel = FrameContainer:new{
        bordersize = UI.line(),
        color = UI.rule(),
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = panel_w, h = panel_h },
        LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = body_h + band_h },
            inner,
        },
    }

    local panel_x = math.floor((w - panel_w) / 2)
    local bottom_gap = UI.sz(56)
    local top_gap = UI.sz(24)
    local panel_y = h - panel_h - bottom_gap
    if panel_y < top_gap then
        panel_y = top_gap
    end
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

-- ── 插件侧生命周期（热区 / 实例 / 回桌面）────────────────

--- 阅读悬浮菜单是否启用。
---@return boolean
function ReaderFloatMenu.enabled()
    return MoonSettings.get().reader_float_menu ~= false
end

--- 关闭并摘掉插件上的悬浮菜单实例。
---@param plugin table|nil
function ReaderFloatMenu.detach(plugin)
    if not plugin or not plugin._reader_float_menu then
        return
    end
    pcall(function()
        plugin._reader_float_menu._closed = true
        UIManager:close(plugin._reader_float_menu)
    end)
    plugin._reader_float_menu = nil
end

--- 阅读中部热区：覆盖左右翻页区中部（宽 50% × 高 50%）。
---@param plugin table|nil
function ReaderFloatMenu.attach(plugin)
    if not plugin or not plugin.ui or not plugin.ui.registerTouchZones then
        return
    end
    if not Device:isTouchDevice() then
        return
    end
    if not ReaderFloatMenu.enabled() then
        return
    end
    plugin.ui:registerTouchZones({
        {
            id = "book_reader_float_menu_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 1 / 4,
                ratio_y = 1 / 4,
                ratio_w = 1 / 2,
                ratio_h = 1 / 2,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
            },
            handler = function()
                return ReaderFloatMenu.onTap(plugin)
            end,
        },
    })
end

--- 中部热区 handler。返回 true 表示已消费，KOReader 不再翻页。
---@param plugin table|nil
---@return boolean
function ReaderFloatMenu.onTap(plugin)
    if not plugin or not ReaderFloatMenu.enabled() then
        return false
    end
    if plugin._reader_float_menu and not plugin._reader_float_menu._closed then
        return true
    end
    local ok, menu = pcall(function()
        return ReaderFloatMenu:new{
            plugin = plugin,
            covers_fullscreen = false,
            close_callback = function()
                plugin._reader_float_menu = nil
            end,
        }
    end)
    if not ok then
        logger.err("book reader float menu failed:", menu)
        return true
    end
    plugin._reader_float_menu = menu
    UIManager:show(menu)
    if menu._panel_dimen then
        UIManager:setDirty("all", "ui", menu._panel_dimen)
        UIManager:setDirty("all", "ui")
    else
        UIManager:setDirty("all", "ui")
    end
    return true
end

--- 退出阅读并打开 Book 桌面。
--- 已在 FM：立刻开。在 Reader：关书 → showFileManager → Host.onShow 消费 want。
---@param plugin table|nil
function ReaderFloatMenu.exitToDesktop(plugin)
    ReaderFloatMenu.detach(plugin)
    local ui = plugin and plugin.ui
    if not (ui and ui.document) then
        if not Host.requestDesktop(plugin) then
            logger.warn("book exitToDesktop: no desktop host")
        end
        return
    end
    local file = ui.document.file
    Host.requestDesktop()
    UIManager:nextTick(function()
        if ui.onClose then
            ui:onClose(false)
        end
        if ui.showFileManager then
            pcall(function()
                ui:showFileManager(file)
            end)
        end
    end)
end

return ReaderFloatMenu
