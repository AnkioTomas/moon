--[[-- 书籍详情：整页布局（标题栏 + 正文）与右上角「更多」菜单。 @module desktop.detail --]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local List = require("ui.themes.widgets.list")
local TitleBar = require("ui.themes.widgets.titlebar")
local _ = require("gettext")

local bookOwnerSource = require("desktop.detail.common").bookOwnerSource

-- 下拉内容宽（逻辑像素）：够放图标 + 「清理缓存」。
local MENU_W = 160

-- actionPlan 工具项 id → 详情页方法名。
local ACTIONS = {
    edit = "openEditor",
    scrape = "startScrape",
    download = "chooseCacheRange",
    download_book = "downloadBook",
    read = "toggleRead",
    unread = "toggleRead",
    clear_cache = "clearCache",
    restore = "restore",
    delete = "deleteBook",
}

return function(Detail)
--- 右上角「更多」：贴着按钮弹出的窄下拉，工具项按 actionPlan 顺序（删除在末尾）。
---@param tools table[] Detail.actionPlan 的工具项
function Detail:showMenu(tools)
    local items = {}
    for i, def in ipairs(tools) do
        local method = ACTIONS[def.id]
        items[i] = { icon = def.icon, text = def.text, callback = function() self[method](self) end }
    end
    local slot = Theme.px(self.theme.control.height)
    List:new{
        centered = true,
        inner_width = Theme.px(MENU_W),
        anchor = { x = self.dimen.w - slot, y = 0, w = slot, h = TitleBar.height() },
        items = items,
    }:show()
end

function Detail:updateView()
    local t = self.theme
    local w, h = self.dimen.w, self.dimen.h
    local pad = Theme.px(t.space.lg)
    local owner = bookOwnerSource(self.book, self.source)
    local tools, primary = {}, nil
    if self.origin == "store" then
        primary = { icon = "add", text = _("加入书库"), callback = function() self:installStoreBook() end }
    else
        tools, primary = Detail.actionPlan(self.book, owner)
        if primary then primary.callback = function() self:openBook() end end
    end

    local bar = TitleBar.widget({
        width = w,
        left_icon = "arrow_back",
        left_callback = function() self:close() end,
        right_icon = #tools > 0 and "more_horiz" or nil,
        right_callback = function() self:showMenu(tools) end,
        divider = false,
    })
    local gap = Theme.px(t.space.xs)
    local body_h = h - bar:getSize().h - gap - pad
    local body = self:buildBody(w - pad * 2, body_h, owner, primary)

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
            VerticalSpan:new{ width = gap },
            HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = pad }, body },
            -- Box 把内容居中：正文短时补足高度，标题栏才贴顶。
            VerticalSpan:new{ width = math.max(0, body_h + pad - body:getSize().h) },
        },
    })
    if old and old.free then old:free() end
end
end
