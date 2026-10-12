--[[-- 书籍详情：整页布局（标题栏 + 正文 + 底部按钮区）。 @module desktop.detail --]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Button = require("ui.themes.widgets.button")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")
local _ = require("gettext")

local bookOwnerSource = require("desktop.detail.common").bookOwnerSource

return function(Detail)
--- 底部按钮区：书城只有「加入书库」；图书馆是工具行 + 阅读主按钮。
---@param width number 物理像素
---@param owner table|nil 属主源
---@return table
function Detail:buildFooter(width, owner)
    if self.origin == "store" then
        return Button:new{ icon = "add", text = _("加入书库"), variant = "primary", width = width,
            callback = function() self:installStoreBook() end }
    end
    local tools, primary = Detail.actionPlan(self.book, owner)
    if #tools == 0 and not primary then
        return Text.line("body", _("暂无可用操作"), { width = width, color = self.theme.color.muted })
    end
    local fns = {
        edit = function() self:openEditor() end,
        scrape = function() self:startScrape() end,
        download = function() self:chooseCacheRange() end,
        download_book = function() self:downloadBook() end,
        read = function() self:toggleRead() end,
        unread = function() self:toggleRead() end,
        clear_cache = function() self:clearCache() end,
        delete = function() self:deleteBook() end,
    }
    local footer = VerticalGroup:new{ align = "center" }
    if #tools > 0 then
        for _idx, def in ipairs(tools) do def.callback = fns[def.id] end
        footer[#footer + 1] = self:buttonRow(tools, width)
    end
    if primary then
        if #footer > 0 then footer[#footer + 1] = VerticalSpan:new{ width = Theme.px(self.theme.space.sm) } end
        footer[#footer + 1] = Button:new{ icon = primary.icon, text = primary.text, variant = "primary", width = width,
            callback = function() self:openBook() end }
    end
    return footer
end

function Detail:updateView()
    local t = self.theme
    local w, h = self.dimen.w, self.dimen.h
    local pad = Theme.px(t.space.md)
    local content_w = w - pad * 2
    local owner = bookOwnerSource(self.book, self.source)
    local can_read = self.origin ~= "store" and owner ~= nil
        and (owner.type == "book" or owner.type == "chapter")

    local bar = TitleBar.widget({
        width = w,
        left_icon = "arrow_back",
        left_callback = function() self:close() end,
    })
    local footer = self:buildFooter(content_w, owner)
    local footer_h = footer:getSize().h + pad * 2
    local body_h = math.max(1, h - bar:getSize().h - footer_h)

    local hero, hero_h = self:buildHero(content_w, self.book, self.origin, can_read)
    local body = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = pad }, hero }
    local content = self:buildContent(content_w, body_h - pad * 3 - hero_h)
    if content then
        body[#body + 1] = VerticalSpan:new{ width = pad }
        body[#body + 1] = content
    end

    -- 先接上新树再释放旧树：reload（刮削/编辑后）会反复重建，旧树里的封面
    -- BlitBuffer 只在 free 时释放，不放就是每次刮削漏一张全屏封面。
    local old = self[1]
    self:setPanel(Box:new{
        style = { bg = t.color.page },
        width = w,
        height = h,
        VerticalGroup:new{
            align = "left",
            bar,
            CenterContainer:new{ dimen = Geom:new{ w = w, h = body_h }, VerticalGroup:new{
                align = "left",
                body,
                VerticalSpan:new{ width = math.max(0, body_h - body:getSize().h) },
            } },
            CenterContainer:new{ dimen = Geom:new{ w = w, h = footer_h }, footer },
        },
    })
    if old and old.free then old:free() end
end
end
