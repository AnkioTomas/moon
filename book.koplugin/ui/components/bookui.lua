--[[--
Book 桌面 UI 缩放 — 字号 / 间距 / 图标统一从这里走。
缩放值存 moon.settings（$DATA/.moon/settings/common.lua 的 ui_scale）
字体族存 common.ui_font，经 moon.font 改 Font.fontmap；UI.face 解析字族。

无自绘页面布局；本模块只吐尺寸/颜色/进度条积木：
  +------------------------+
  |  [====····] progressBar|
  |  ─ line / rule 色      |
  |  sz / face / iconSz …  |
  +------------------------+

约定：
  UI.sz(n)       间距、控件几何（含 DPI + ui_scale）
  UI.face(...)   Font:getFace 包装（TextWidget / TitleBar / TextBox 用）
  UI.fontSize(n) 交给 Button/Menu 的数字字号
  UI.iconSz()    图标边长
  UI.line()      分割线粗细
  UI.pluginRoot()  插件根路径（图标字体等资源）

@module koplugin.book.ui.components.bookui
--]]

local Device = require("device")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local MoonSettings = require("utils.settings")
local Screen = Device.screen

local UI = {}

local _plugin_root

--- 插件根目录（…/book.koplugin/），带尾斜杠。
---@return string
function UI.pluginRoot()
    if _plugin_root then
        return _plugin_root
    end
    local info = debug.getinfo(UI.pluginRoot, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        -- …/book.koplugin/ui/components/bookui.lua
        local root = src:sub(2):match("(.*/)ui/components/[^/]+$")
        if root then
            _plugin_root = root
            return _plugin_root
        end
    end
    local searched = package.searchpath and package.searchpath("ui.components.bookui", package.path)
    if type(searched) == "string" then
        local root = searched:match("(.*/)ui/components/[^/]+$")
        if root then
            _plugin_root = root
            return _plugin_root
        end
    end
    _plugin_root = ""
    return _plugin_root
end

local DEFAULT_SCALE = 130
local MIN_SCALE = 100
local MAX_SCALE = 180
local STEP = 10

--- UI 缩放下限（百分比）。
---@return number
function UI.scaleMin()
    return MIN_SCALE
end

--- UI 缩放上限（百分比）。
---@return number
function UI.scaleMax()
    return MAX_SCALE
end

--- UI 缩放步进（百分比）。
---@return number
function UI.scaleStep()
    return STEP
end

--- 读取当前 UI 缩放百分比。
---@return number
function UI.getScale()
    local s = MoonSettings.get()
    local n = tonumber(s.ui_scale) or DEFAULT_SCALE
    if n < MIN_SCALE then n = MIN_SCALE end
    if n > MAX_SCALE then n = MAX_SCALE end
    return n
end

--- 写入并夹紧 UI 缩放百分比。
---@param n number|nil
---@return number
function UI.setScale(n)
    n = tonumber(n) or DEFAULT_SCALE
    if n < MIN_SCALE then n = MIN_SCALE end
    if n > MAX_SCALE then n = MAX_SCALE end
    n = math.floor((n + STEP / 2) / STEP) * STEP
    local s = MoonSettings.get()
    s.ui_scale = n
    MoonSettings.save(s)
    return n
end

--- 循环切换到下一档缩放。
---@return number
function UI.cycleScale()
    local n = UI.getScale() + STEP
    if n > MAX_SCALE then n = MIN_SCALE end
    return UI.setScale(n)
end

--- 逻辑像素 → 物理像素，再乘 ui_scale。
---@param n number
---@return number
function UI.sz(n)
    return math.max(1, math.floor(Screen:scaleBySize(n) * UI.getScale() / 100 + 0.5))
end

--- 纯数字字号（Font / Button.text_font_size / Menu.items_font_size）。
---@param size number|nil
---@return number
function UI.fontSize(size)
    return math.max(10, math.floor((size or 16) * UI.getScale() / 100 + 0.5))
end

--- Font:getFace 的缩放包装（字族经 Font.fontmap，含 ui_font）。
---@param name string
---@param size number|nil
---@return table
function UI.face(name, size)
    return Font:getFace(name, UI.fontSize(size))
end

--- 分割线粗细（至少 1px）。
---@return number
function UI.line()
    return math.max(1, UI.sz(1))
end

--- 标准图标边长。
---@return number
function UI.iconSz()
    return UI.sz(24)
end

--- 弱化文字色（深灰接近黑）。
---@return any
function UI.muted()
    return Blitbuffer.COLOR_GRAY_3 -- 0x33，深灰接近黑
end

--- 更淡的弱化色。
---@return any
function UI.dim()
    return Blitbuffer.COLOR_GRAY_4 -- 0x44
end

--- 分割线颜色。
---@return any
function UI.rule()
    return Blitbuffer.COLOR_GRAY_5 -- 0x55，分割线可见
end

--- 进度条空轨颜色。
---@return any
function UI.track()
    return Blitbuffer.COLOR_LIGHT_GRAY -- 0xCC，空轨浅但不飘
end

--- TitleBar 关闭等图标：把目标边长折算成 size_ratio。
---@param base_ratio number|nil
---@return number
function UI.titleIconRatio(base_ratio)
    base_ratio = base_ratio or 0.6
    local ok, defaults = pcall(function()
        return G_defaults:readSetting("DGENERIC_ICON_SIZE")
    end)
    local base = (ok and tonumber(defaults)) or 32
    local native = Screen:scaleBySize(base * base_ratio)
    if native < 1 then native = 1 end
    return UI.iconSz() / native * base_ratio
end

--- 底栏高度。
---@return number
function UI.barH()
    -- 图标 + 文字 + 上下空隙，随字号一起长
    return math.max(UI.sz(56), UI.iconSz() + UI.sz(32))
end

--- 各页统一内容边距（首页 / 书架 / 统计 / 设置 / 详情）。
---@return number
function UI.pagePad()
    return UI.sz(16)
end

--- 节与节之间的垂直间距。
---@return number
function UI.sectionGap()
    return UI.sz(18)
end

--- Desktop 顶部系统状态条高度（容纳小图标 + 分段电池）。
---@return number
function UI.topBarH()
    return math.max(UI.sz(32), UI.fontSize(12) + UI.sz(16))
end

--- 菜单项字号。
---@return number
function UI.menuFontSize()
    return UI.fontSize(22)
end

--- 按钮字号。
---@return number
function UI.buttonFontSize()
    return UI.fontSize(20)
end

--- 网格封面高度上限：跟屏高走，避免宽屏三列把封面撑到半屏。
---@param area_h number|nil
---@return number
function UI.gridCoverMaxH(area_h)
    local screen_h = Screen:getHeight()
    area_h = tonumber(area_h) or screen_h
    -- 约屏高 21%；下限抬高，避免「经常显得太小」
    local max_h = math.max(UI.sz(100), math.min(UI.sz(156), math.floor(screen_h * 0.21)))
    if area_h > 0 and area_h < screen_h then
        local title_extra = UI.sz(26)
        local row_gap = UI.sz(12)
        -- 尽量两行，但不把单本压得过狠：两行预算至少保住 max_h 的 85%
        local two_row = math.floor((area_h - row_gap) / 2 - title_extra)
        if two_row >= UI.sz(80) then
            max_h = math.min(max_h, math.max(two_row, math.floor(max_h * 0.85)))
        end
    end
    return max_h
end

--- 密铺封面网格：按可用宽度选列数，封面约 2:3。
--- opts: title_extra / min_cols / max_cols / min_cw / target_cw / gap / row_gap
---@param avail_w number
---@param budget_h number
---@param opts table|nil
---@return number, number, number, number, number, number, number
function UI.denseCoverMetrics(avail_w, budget_h, opts)
    opts = opts or {}
    avail_w = math.max(1, math.floor(tonumber(avail_w) or 1))
    budget_h = math.max(0, math.floor(tonumber(budget_h) or 0))
    local gap = opts.gap or UI.sz(8)
    local row_gap = opts.row_gap or UI.sz(14)
    local min_cw = opts.min_cw or UI.sz(52)
    local target_cw = opts.target_cw or UI.sz(72)
    local min_cols = opts.min_cols or 3
    local max_cols = opts.max_cols or 5
    local title_extra = opts.title_extra or 0
    local max_h = opts.max_h or UI.gridCoverMaxH(budget_h > 0 and budget_h or nil)

    --- 给定列数时的格子宽。
    ---@param c number
    ---@return number
    local function slotFor(c)
        return math.floor((avail_w - gap * (c - 1)) / c)
    end

    -- 按目标列宽估列数，再夹到 [min,max]，并保证 slot >= min_cw
    local cols = math.floor((avail_w + gap) / (target_cw + gap) + 0.5)
    if cols < min_cols then cols = min_cols end
    if cols > max_cols then cols = max_cols end
    while cols > min_cols and slotFor(cols) < min_cw do
        cols = cols - 1
    end
    -- 封面按列宽算出的高度仍超上限 → 加列压矮
    while cols < max_cols and math.floor(slotFor(cols) * 3 / 2) > max_h do
        if slotFor(cols + 1) < min_cw then
            break
        end
        cols = cols + 1
    end

    local slot_w = math.max(1, slotFor(cols))
    local cw = slot_w
    local ch = math.floor(cw * 3 / 2)
    local cell_h = ch + title_extra

    -- 垂直方向不够两行时，压封面高度（保持约 2:3，不超出格子宽）
    if budget_h > 0 and cell_h * 2 + row_gap > budget_h then
        local fit = math.floor((budget_h - row_gap) / 2) - title_extra
        if fit >= UI.sz(64) then
            ch = fit
            cw = math.max(1, math.floor(ch * 2 / 3))
            if cw > slot_w then
                cw = slot_w
                ch = math.floor(cw * 3 / 2)
            end
            cell_h = ch + title_extra
        end
    end

    return slot_w, cw, ch, cols, gap, row_gap, cell_h
end

--- 网格尺度：列宽铺满屏幕；封面在格子里保持 2:3。
--- 返回 slot_w, cover_w, cover_h, cols, gap
---@param avail_w number
---@param area_h number
---@param opts table|nil
---@return number, number, number, number, number
function UI.coverGridMetrics(avail_w, area_h, opts)
    opts = opts or {}
    local title_extra = opts.title_extra or 0
    local slot_w, cw, ch, cols, gap = UI.denseCoverMetrics(avail_w, area_h, {
        gap = opts.gap or UI.sz(12),
        min_cw = opts.min_cw,
        min_cols = opts.min_cols,
        max_cols = opts.max_cols,
        target_cw = opts.target_cw or opts.min_cw or UI.sz(56),
        title_extra = title_extra,
        row_gap = opts.row_gap,
        max_h = opts.max_h,
    })
    return slot_w, cw, ch, cols, gap
end

--- 最近阅读主角封面最大高度。
---@return number
function UI.coverMaxH()
    local screen_h = Screen:getHeight()
    return math.max(UI.sz(104), math.min(UI.sz(172), math.floor(screen_h * 0.26)))
end

--- 主角封面：超高则压高度并回缩宽度，保持约 2:3。
---@param cw number
---@return number, number
function UI.coverDim(cw)
    cw = math.max(1, math.floor(tonumber(cw) or 1))
    local ch = math.floor(cw * 3 / 2)
    local max_h = UI.coverMaxH()
    if ch > max_h then
        ch = max_h
        cw = math.max(1, math.floor(ch * 2 / 3))
    end
    return cw, ch
end

--- 简易进度条（0–100）。优先 ProgressWidget；否则用 LineWidget，禁止空 FrameContainer。
---@param width number
---@param height number|nil
---@param percent number|nil
---@return table
function UI.progressBar(width, height, percent)
    local Geom = require("ui/geometry")
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or UI.sz(8)))
    percent = tonumber(percent) or 0
    if percent < 0 then percent = 0 end
    if percent > 100 then percent = 100 end

    local ok, ProgressWidget = pcall(require, "ui/widget/progresswidget")
    if ok and ProgressWidget then
        local widget = ProgressWidget:new{
            width = width,
            height = height,
            percentage = percent / 100,
        }
        if widget then
            return widget
        end
    end

    local LineWidget = require("ui/widget/linewidget")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local fill_w = math.floor(width * percent / 100 + 0.5)
    if fill_w < 0 then fill_w = 0 end
    if fill_w > width then fill_w = width end
    local empty_w = width - fill_w
    local row = HorizontalGroup:new{}
    if fill_w > 0 then
        table.insert(row, LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = fill_w, h = height },
        })
    end
    if empty_w > 0 then
        table.insert(row, LineWidget:new{
            background = UI.track(),
            dimen = Geom:new{ w = empty_w, h = height },
        })
    end
    if #row == 0 then
        local TextWidget = require("ui/widget/textwidget")
        return TextWidget:new{
            text = string.format("%.0f%%", percent),
            face = UI.face("xx_smallinfofont", 12),
            fgcolor = UI.muted(),
        }
    end
    local border = UI.line()
    return FrameContainer:new{
        bordersize = border,
        color = UI.rule(),
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width + border * 2, h = height + border * 2 },
        row,
    }
end

return UI
