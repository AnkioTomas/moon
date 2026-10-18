--[[--
书架封面格子：纯书籍卡片（封面 + 书名，作者按需）外包一层点击分流。
图书馆网格与首页最近阅读列表共用。

@module koplugin.book.ui.widgets.cover
--]]

local Book = require("ui.widgets.book")
local Device = require("device")
local MoonSettings = require("utils.settings")
local UIManager = require("ui/uimanager")
local Theme = require("ui.themes")
local Tap = require("ui.themes.widgets.tap")
local _ = require("gettext")

local CoverCell = {}

--- 揭掉上一本封面的「正在打开」条。
---@param owner table 持有打开中状态的视图实例
local function clearOpening(owner)
    local cover, bar = owner._opening_cover, owner._opening_bar
    owner._opening_cover, owner._opening_bar = nil, nil
    if not cover or not bar then return end
    for i = #cover, 1, -1 do
        if cover[i] == bar then
            table.remove(cover, i)
            break
        end
    end
    if bar.free then bar:free() end
end

--- 点封面打开书的回调：封面盖「正在打开」条，打开结束或改开另一本时揭掉。
---@param owner table 持有 _opening_cover/_opening_bar/_open_token 的视图实例
---@param ctx table 构建上下文，提供插件与桌面宿主
---@param open fun(plugin: BookPlugin, book: Book, done: fun()) 打开书（由调用方注入，ui 层不反向依赖 desktop）
---@return fun(book: Book, cover: table, cw: number, ch: number)
function CoverCell.opener(owner, ctx, open)
    return function(book, cover, cw, ch)
        local desktop = ctx.desktop
        local plugin = ctx.plugin or (desktop and desktop.plugin)
        if not plugin then return end
        clearOpening(owner)
        local bar = Book.openingBar(cw, ch)
        cover[#cover + 1] = bar
        owner._opening_cover, owner._opening_bar = cover, bar
        local token = {}
        owner._open_token = token
        if desktop then UIManager:setDirty(desktop, "ui") end
        UIManager:nextTick(require("ui.guard").wrap("open book", function()
            if owner._open_token ~= token then return end
            open(plugin, book, function()
                if owner._open_token ~= token then return end
                owner._open_token = nil
                clearOpening(owner)
                if desktop then UIManager:setDirty(desktop, "ui") end
            end)
        end))
    end
end

--- 构建封面格子；show_status 为 false 时不画状态角标与「更多」，整卡即 on_open。
--- show_author 缺省关闭。打开后格子变高，调用方要用同样的开关算槽高。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param book Book 当前操作或展示的书籍数据
---@param slot_w number 单个封面槽位宽度，单位像素
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@param on_open fun(book: Book, cover: table, cw: number, ch: number)
---@param show_status boolean|nil 是否显示书籍状态信息，缺省显示
---@param show_title boolean|nil 是否在封面下显示书名，缺省显示
---@param show_author boolean|nil 是否在书名下显示作者，缺省不显示
---@param lib table|nil CoverCell.libraryConf() 的结果；缺省为首页 / 书城的固定样式
---@return table, number
function CoverCell.build(ctx, book, slot_w, cw, ch, on_open, show_status, show_title, show_author, lib)
    local status = show_status ~= false
    local opts = {
        slot_w = slot_w,
        show_title = show_title,
        show_author = show_author == true,
        badge = true,
        ribbon = status,
        download = status,
        -- 图书馆右下角「更多」进详情（角标自带点击区，先于整卡收到点按）；书城整卡即详情，不画「更多」。
        more = status and function() ctx.on_detail(book) end,
        show_parent = ctx.desktop,
    }
    if lib and lib.kobo then
        -- Kobo：封面上不留东西，下载状态 / 进度 / 更多都收到封面下一行。
        opts.badge, opts.ribbon, opts.download, opts.more = false, false, false, false
        opts.status_row = status
        if status then
            -- 未下载优先，已下载显示阅读进度条。
            if book.downloaded == false then
                opts.status_text = _("未下载")
            else
                opts.status_pct = Book.isRead(book) and 100 or Book.pct(book)
            end
            opts.status_more = function() ctx.on_detail(book) end
        end
    end
    local card, _card_h, cover = Book.widget(ctx.plugin, ctx.source, book, cw, ch, opts)
    local tap = Tap.wrap(card, function() on_open(book, cover, cw, ch) end)
    return tap, tap:getSize().h
end

--- 图书馆网格的显示配置（settings/ui.lua 的 library_*）；kobo 为真时用 Kobo 风格。
---@return table
function CoverCell.libraryConf()
    local conf = MoonSettings.get("ui")
    return {
        title = conf.library_title,
        author = conf.library_author,
        kobo = conf.library_style == "kobo",
        tap_detail = conf.library_tap == "detail",
    }
end

local GRID_MIN, GRID_MAX, GRID_DEFAULT = 3, 8, 4
local Screen = Device.screen

function CoverCell.gridColsMin()
    return GRID_MIN
end

function CoverCell.gridColsMax()
    return GRID_MAX
end

--- 书架每行封面数，夹在 3–8。
---@return number
function CoverCell.gridCols()
    local n = math.floor(tonumber(MoonSettings.get("ui").grid_max_cols) or GRID_DEFAULT)
    return math.max(GRID_MIN, math.min(GRID_MAX, n))
end

--- 写入书架每行封面数。
---@param n number|nil
---@return number
function CoverCell.setGridCols(n)
    n = math.floor(tonumber(n) or GRID_DEFAULT)
    n = math.max(GRID_MIN, math.min(GRID_MAX, n))
    local display = MoonSettings.get("ui")
    display.grid_max_cols = n
    MoonSettings.save("ui", display)
    return n
end

--- 网格封面高度上限：跟屏高走，避免宽屏把封面撑到半屏。
---@param area_h number|nil
---@return number
function CoverCell.gridCoverMaxH(area_h)
    local screen_h = Screen:getHeight()
    area_h = tonumber(area_h) or screen_h
    local max_h = math.max(Theme.px(100), math.min(Theme.px(156), math.floor(screen_h * 0.21)))
    if area_h > 0 and area_h < screen_h then
        local title_extra = Theme.px(26)
        local row_gap = Theme.px(12)
        local two_row = math.floor((area_h - row_gap) / 2 - title_extra)
        if two_row >= Theme.px(80) then
            max_h = math.min(max_h, math.max(two_row, math.floor(max_h * 0.85)))
        end
    end
    return max_h
end

--- 密铺封面网格：按可用宽度选列数，封面约 2:3。
--- opts: title_extra / min_cols / max_cols / min_cw / target_cw / gap / row_gap / max_h
---@param avail_w number
---@param budget_h number
---@param opts table|nil
---@return number, number, number, number, number, number, number
function CoverCell.denseCoverMetrics(avail_w, budget_h, opts)
    opts = opts or {}
    avail_w = math.max(1, math.floor(tonumber(avail_w) or 1))
    budget_h = math.max(0, math.floor(tonumber(budget_h) or 0))
    local gap = opts.gap or Theme.px(Theme.current().space.sm)
    local row_gap = opts.row_gap or Theme.px(14)
    local min_cw = opts.min_cw or Theme.px(52)
    local target_cw = opts.target_cw or Theme.px(72)
    local max_cols = opts.max_cols or CoverCell.gridCols()
    local min_cols = math.min(opts.min_cols or 3, max_cols)
    local title_extra = opts.title_extra or 0
    local max_h = opts.max_h or CoverCell.gridCoverMaxH(budget_h > 0 and budget_h or nil)

    local function slotFor(c)
        return math.floor((avail_w - gap * (c - 1)) / c)
    end

    local cols = math.floor((avail_w + gap) / (target_cw + gap) + 0.5)
    if cols < min_cols then cols = min_cols end
    if cols > max_cols then cols = max_cols end
    while cols > min_cols and slotFor(cols) < min_cw do
        cols = cols - 1
    end
    while cols < max_cols and math.floor(slotFor(cols) * 3 / 2) > max_h do
        if slotFor(cols + 1) < min_cw then break end
        cols = cols + 1
    end

    local slot_w = math.max(1, slotFor(cols))
    local cw = slot_w
    local ch = math.floor(cw * 3 / 2)
    local cell_h = ch + title_extra
    if budget_h > 0 and cell_h * 2 + row_gap > budget_h then
        local fit = math.floor((budget_h - row_gap) / 2) - title_extra
        if fit >= Theme.px(64) then
            ch = fit
            cw = math.max(1, math.floor(ch * 2 / 3))
            if cw > slot_w then
                cw = slot_w
                ch = math.floor(cw * 3 / 2)
            end
            cell_h = ch + title_extra
        end
    end
    cw = CoverCell.stretchW(slot_w, cw, ch)
    return slot_w, cw, ch, cols, gap, row_gap, cell_h
end

--- 封面按高度压矮后，宽度向槽宽拉伸（最宽 3:4），免得列间空隙过大。
---@param slot_w number
---@param cw number
---@param ch number
---@return number
function CoverCell.stretchW(slot_w, cw, ch)
    return math.max(cw, math.min(slot_w, math.floor(ch * 3 / 4)))
end

--- 主角封面：超过最大高度则压高度并回缩宽度，保持约 2:3。
---@param cw number
---@return number, number
function CoverCell.coverDim(cw)
    cw = math.max(1, math.floor(tonumber(cw) or 1))
    local ch = math.floor(cw * 3 / 2)
    local max_h = math.max(Theme.px(104), math.min(Theme.px(172), math.floor(Screen:getHeight() * 0.26)))
    if ch > max_h then
        ch = max_h
        cw = math.max(1, math.floor(ch * 2 / 3))
    end
    return cw, ch
end

return CoverCell
