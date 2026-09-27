--[[--
侧栏票根页：锁屏「阅读票根」主体画成整屏 PNG，侧栏缩放展示，同一张图经远程管理分享。

书跟阅读身份走（Current.snapshot），不取锁屏的「当前源最近在读」。

@module koplugin.book.ui.reader.sidebar.ticket
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Paths = require("utils.paths")
local UI = require("ui.components.bookui")
local T = require("ffi/util").template
local _ = require("gettext")

---@class BookSidebarTicket
---@field path string 票根 PNG
---@field ready boolean PNG 已写好
---@field err any 生成失败原因
---@field job table|nil 等封面落定的任务
---@field blocks table[]|nil 待绘制的块（含离屏封面 widget）
local Ticket = {}
Ticket.__index = Ticket

--- 按当前阅读会话生成票根；封面落定后写 PNG 并回调 on_ready（可能同步回调）。
---@param snapshot ReaderSessionSnapshot
---@param on_ready fun()
---@return BookSidebarTicket
function Ticket.new(snapshot, on_ready)
    local Current = require("lockscreen.components.current")
    local Layout = require("lockscreen.layout")
    local Receipt = require("lockscreen.components.receipt")
    local Session = require("ui.reader.session")
    local book = require("ui.reader.sidebar.info").book(snapshot)
    local self = setmetatable({ path = Paths.screensaverDir() .. "/ticket.png", ready = false }, Ticket)
    local sw, sh = Layout.portraitSize()
    self.blocks = Receipt.blocks(Layout.panel{
        position = "center-center",
        wide = true,
        height = math.floor(sh * Receipt.preferred_height),
        screen_w = sw,
        screen_h = sh,
    }, Current.snapshot{
        source_id = book.source_id,
        stable_id = book.stable_id,
        title = book.title,
        authors = book.authors,
        percent = snapshot.percent,
        page = snapshot.page,
        total_pages = snapshot.total_pages,
        chapter_idx = Session.chapterIndex(snapshot),
        chapter_title = Session.chapterTitle(snapshot),
    })
    local widgets = {}
    for _, block in ipairs(self.blocks) do
        if block.widget then widgets[#widgets + 1] = block.widget end
    end
    self.job = require("ui.components.image").await(widgets, function()
        local blocks = self.blocks
        self.blocks = nil -- Render.write 消费离屏 widget
        -- 灰底：票根白卡、齿孔和撕线缺口才看得出来
        self.ready, self.err = require("lockscreen.render").write(self.path, nil, blocks, Blitbuffer.COLOR_GRAY_E)
        on_ready()
    end)
    return self
end

--- 关侧栏时取消：还没画的离屏封面由这里释放。
function Ticket:cancel()
    self.job:cancel()
    for _, block in ipairs(self.blocks or {}) do
        if block.widget and block.widget.free then block.widget:free() end
    end
    self.blocks = nil
end

--- 票根页内容：缩放后的票根图 + 分享按钮；未就绪时显示状态文案。
---@param width number
---@param height number
---@return table
function Ticket:widget(width, height)
    if not self.ready then
        local text = self.err and T(_("票根生成失败：%1"), tostring(self.err)) or _("正在生成票根…")
        return CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            UI.mutedText(text, width - UI.pagePad() * 2, 14),
        }
    end
    local share = Button:new{
        text = _("分享"),
        width = width - UI.pagePad() * 2,
        callback = function() require("remote.screenshot").share(self.path) end,
    }
    local image_h = height - share:getSize().h - UI.pagePad() * 2
    return VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = image_h + UI.pagePad() },
            ImageWidget:new{
                file = self.path,
                file_do_cache = false, -- 同一路径每次重画，缓存会拿到上一张
                width = width - UI.pagePad() * 2,
                height = image_h,
                scale_factor = 0,
            },
        },
        share,
    }
end

return Ticket
