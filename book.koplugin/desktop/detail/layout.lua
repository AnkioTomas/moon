--[[-- 书籍详情：整页布局（标题栏 + 正文）与右上角「更多」菜单。 @module desktop.detail --]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
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
--- 贴着锚点弹出的窄下拉，工具项按 actionPlan 顺序（删除在末尾）。
---@param self table Detail 实例，或 Detail.openMenu 造的宿主
---@param tools table[] Detail.actionPlan 的工具项
---@param anchor table 锚点矩形 { x, y, w, h }
local function showTools(self, tools, anchor)
    local items = {}
    for i, def in ipairs(tools) do
        local method = ACTIONS[def.id]
        items[i] = { icon = def.icon, text = def.text, callback = function() self[method](self) end }
    end
    List:new{ centered = true, inner_width = Theme.px(MENU_W), anchor = anchor, items = items }:show()
end

--- 右上角「更多」。
---@param tools table[] Detail.actionPlan 的工具项
function Detail:showMenu(tools)
    local slot = Theme.px(self.theme.control.height)
    showTools(self, tools, { x = self.dimen.w - slot, y = 0, w = slot, h = TitleBar.height() })
end

--- 不开详情页，直接弹详情页右上角同一份菜单（书库「更多」用）。
--- 宿主只带动作要用的字段；没有详情页可关 / 可重画，改动后重建桌面。
---@param desktop table BookDesktop
---@param book table
---@param anchor table 触发按钮的矩形
function Detail.openMenu(desktop, book, anchor)
    local tools = Detail.actionPlan(book, bookOwnerSource(book, desktop.source))
    if #tools == 0 then return end
    local function rebuild()
        desktop:onEvent("detail_dirty")
        if desktop.tab ~= "home" then desktop:updateView() end
        UIManager:setDirty(desktop, "ui")
    end
    local host = setmetatable({
        book = book, plugin = desktop.plugin, source = desktop.source, desktop = desktop, origin = "library",
        close = rebuild,
        reload = function()
            desktop:onEvent("shelf_changed")
            rebuild()
        end,
    }, { __index = Detail })
    showTools(host, tools, anchor)
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
