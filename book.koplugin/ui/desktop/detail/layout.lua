--[[-- 书籍详情子模块。 @module ui.desktop.detail --]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local _ = require("gettext")
local Screen = Device.screen


local Common = require("ui.desktop.detail.common")
local bookOwnerSource = Common.bookOwnerSource
local actionChip = Common.actionChip
local chipRow = Common.chipRow

return function(Detail)
function Detail:updateView()
    local book = self.book or {}
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local pad = UI.pagePad()
    local content_w = w - pad * 2

    local store_book = self.origin == "store"
    local owner = bookOwnerSource(book, self.source)
    local can_read = not store_book and owner ~= nil
        and (owner.type == "book" or owner.type == "chapter")

    local title_bar, title_h = self:buildTopBar(w)

    -- 底部最多两行：Z站只有加入书库（与图书馆主按钮同款 chip）；图书馆是工具行 + 阅读主操作。
    local footer_pad_v = UI.sz(12)
    local footer, footer_h
    if store_book then
        local read_h = UI.sz(44)
        footer = actionChip(content_w, read_h, "add", _("加入书库"), function()
            self:installStoreBook()
        end)
        footer_h = read_h + footer_pad_v * 2
    else
        local tools, primary = Detail.actionPlan(book, owner, self.origin)
        local fns = {
            edit = function() self:openEditor() end,
            scrape = function() self:startScrape() end,
            download = function() self:cacheAllChapters() end,
            read = function() self:toggleRead() end,
            unread = function() self:toggleRead() end,
            delete = function() self:deleteBook() end,
        }
        local tool_chips = {}
        for _, def in ipairs(tools) do
            tool_chips[#tool_chips + 1] = {
                icon = def.icon,
                text = def.text,
                fn = fns[def.id],
            }
        end
        local tools_h = UI.sz(56)
        local read_h = UI.sz(44)
        local row_gap = UI.sz(8)
        if #tool_chips == 0 and not primary then
            footer = TextWidget:new{
                text = _("暂无可用操作"),
                face = UI.face("xx_smallinfofont", 13),
                max_width = content_w,
                fgcolor = UI.muted(),
            }
            footer_h = footer:getSize().h + footer_pad_v * 2
        else
            local kids = VerticalGroup:new{ align = "center" }
            footer_h = footer_pad_v * 2
            local function appendRow(row, height)
                if kids[1] then
                    table.insert(kids, VerticalSpan:new{ width = row_gap })
                    footer_h = footer_h + row_gap
                end
                table.insert(kids, row)
                footer_h = footer_h + height
            end
            if #tool_chips > 0 then
                -- 工具按钮统一为左图标右文字；整行仍保持单行布局。
                appendRow(chipRow(content_w, tools_h, tool_chips, "row"), tools_h)
            end
            if primary then
                appendRow(actionChip(content_w, read_h, primary.icon, primary.text, function()
                    self:openBook()
                end), read_h)
            end
            footer = kids
        end
    end

    local body_h = math.max(UI.sz(80), h - title_h - footer_h)
    local body_inner_h = math.max(UI.sz(60), body_h - pad - UI.sz(12))

    -- 顶部：书籍信息英雄卡（封面 / 书名 / 作者 / 分类·系列 / 简介摘要 / 进度条）
    local hero, hero_h = self:buildHero(content_w, book, self.origin, can_read)

    local gap = UI.sz(12)
    local body_kids = { align = "left", hero }

    local content = self:buildContent(content_w, body_inner_h, self.origin, hero_h)
    if content then
        table.insert(body_kids, VerticalSpan:new{ width = gap })
        table.insert(body_kids, content)
    end

    local root_kids = {
        align = "left",
        title_bar,
        FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = UI.sz(12),
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = body_h },
            -- 顶对齐：内容都是满宽的，水平居中无视觉效果；
            -- 用 LeftContainer 会在内容不足时垂直居中（残影式的“飘在��间”）
            TopContainer:new{
                dimen = Geom:new{ w = content_w, h = body_inner_h },
                VerticalGroup:new(body_kids),
            },
        },
        FrameContainer:new{
            bordersize = 0,
            padding = pad,
            padding_top = footer_pad_v,
            padding_bottom = footer_pad_v,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = footer_h },
            footer,
        },
    }

    -- 先接上新树再释放旧树：reload（刮削/编辑后）会反复 rebuild，旧树里的封面
    -- BlitBuffer 只在 free 时释放，不放就是每次刮削漏一张全屏封面。
    local old = self[1]
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new(root_kids),
    }
    if old and old.free then
        old:free()
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

end
