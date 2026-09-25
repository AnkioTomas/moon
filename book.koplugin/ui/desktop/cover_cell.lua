--[[--
书架封面格子：封面 + 可选单行书名。图书馆网格与首页最近阅读列表共用。

@module koplugin.book.ui.desktop.cover_cell
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local CoverCell = {}

--- 封面下方书名与间隔的总高度。
---@return number
function CoverCell.titleExtra()
    return UI.sz(4) + UI.sz(22)
end

--- 打开书籍详情；Z站页进详情时带 store 来源。
---@param ctx table 构建上下文
---@param book Book
function CoverCell.openDetail(ctx, book)
    require("ui.desktop.detail").open(ctx.desktop, ctx.desktop.tab == "store" and "store" or "library", book)
end

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
---@return fun(book: Book, cover: table, cw: number, ch: number)
function CoverCell.opener(owner, ctx)
    return function(book, cover, cw, ch)
        local desktop = ctx.desktop
        local plugin = ctx.plugin or (desktop and desktop.plugin)
        if not plugin then return end
        clearOpening(owner)
        local bar = BookInfo.openingBar(cw, ch)
        cover[#cover + 1] = bar
        owner._opening_cover, owner._opening_bar = cover, bar
        local token = {}
        owner._open_token = token
        if desktop then UIManager:setDirty(desktop, "ui") end
        UIManager:nextTick(function()
            if owner._open_token ~= token then return end
            require("book.open").book(plugin, book, function()
                if owner._open_token ~= token then return end
                owner._open_token = nil
                clearOpening(owner)
                if desktop then UIManager:setDirty(desktop, "ui") end
            end)
        end)
    end
end

--- 构建封面格子；show_status 为 false 时不画状态角标与「更多」，整卡即 on_open。
---@param ctx table 构建上下文，提供尺寸、数据源和桌面宿主
---@param book Book 当前操作或展示的书籍数据
---@param slot_w number 单个封面槽位宽度，单位像素
---@param cw number 封面宽度，单位像素
---@param ch number 封面高度，单位像素
---@param on_open fun(book: Book, cover: table, cw: number, ch: number)
---@param show_status boolean|nil 是否显示书籍状态信息，缺省显示
---@param show_title boolean|nil 是否在封面下显示书名，缺省显示
---@return table, number
function CoverCell.build(ctx, book, slot_w, cw, ch, on_open, show_status, show_title)
    local status = show_status ~= false
    local cover = select(1, BookInfo.cover(ctx.plugin, ctx.source, book, cw, ch, {
        badge = true,
        ribbon = status,
        download = status,
        -- 图书馆右下角进详情；Z站整卡即详情，不画「更多」。
        more = status,
        show_parent = ctx.desktop,
    }))
    local extra = show_title == false and 0 or CoverCell.titleExtra()
    local total_h = ch + extra
    local tap = BookInfo.tappable(slot_w, total_h, function()
        on_open(book, cover, cw, ch)
    end)
    --- 一个手势容器完成分流，避免封面与更多按钮嵌套后争抢同名事件。
    ---@param _ table
    ---@param ges table|nil
    ---@return boolean
    tap.onTapBookInfo = function(_, _arg, ges)
        local pos, dimen = ges and ges.pos, tap.dimen
        if status and pos and dimen then
            local size, inset = UI.sz(18), UI.sz(4)
            local cover_x = dimen.x + math.floor((slot_w - cw) / 2)
            if pos.x >= cover_x + cw - size - inset
                and pos.x < cover_x + cw - inset
                and pos.y >= dimen.y + ch - size - inset
                and pos.y < dimen.y + ch - inset then
                CoverCell.openDetail(ctx, book)
                return true
            end
        end
        on_open(book, cover, cw, ch)
        return true
    end
    local kids = {
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = ch },
            cover,
        },
    }
    if extra > 0 then
        kids[#kids + 1] = VerticalSpan:new{ width = UI.sz(4) }
        kids[#kids + 1] = TextWidget:new{
            text = BookInfo.title(book),
            face = UI.face("xx_smallinfofont", 13),
            max_width = slot_w,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    tap[1] = VerticalGroup:new(kids)
    return tap, total_h
end

return CoverCell
