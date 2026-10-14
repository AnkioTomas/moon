--[[--
阅读页顶栏 / 底栏组合页：替代系统栏、跟随系统开关、全宽预览、组件左右与顺序。

@module koplugin.book.features.bars.page
--]]

local UIManager = require("ui/uimanager")
local Sheet = require("ui.themes.widgets.sheet")
local Position = require("desktop.pages.setting.position")
local Row = require("ui.themes.widgets.row")
local Spin = require("ui.themes.widgets.spin")
local Bars = require("features.bars")
local Items = require("features.bars.items")
local Layout = require("features.bars.layout")
local Preview = require("features.bars.preview")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookReaderBarPage
---@field preview fun(width: number): table
---@field sections table[]

---@class BookSettingsReaderBar
---@field page fun(self: BookSettingsReaderBar, desktop: table, which: string): BookReaderBarPage
local ReaderBar = {}
---@return table|nil
--- 正在阅读的 ReaderUI。关书时 closeDocument 先清 document，onCloseWidget 才清 instance，
--- 中间这段 instance 已不可用；偏好照常落盘，下次开书由 Bars.applyPreferences 应用。
local function readerUi()
    local ui = require("apps/reader/readerui").instance
    return ui and ui.document and ui or nil
end

local function refreshReaderUi()
    local ui = readerUi()
    if ui and ui.dialog then
        UIManager:setDirty(ui.dialog, "ui")
    end
end

local footerSettings = Preview.footerSettings

--- 底栏字号写回 KOReader 状态栏，两边保持一致。没开过书、全局也没有 footer 设置时只存月读这份，
--- 不凭空造一张不完整的 footer 表。
---@param size number
local function writeFooterFont(size)
    local settings, footer = footerSettings()
    if not settings then return end
    settings.text_font_size = size
    if footer then
        if footer.updateFooterFont then footer:updateFooterFont() end
        if footer.refreshFooter then footer:refreshFooter(true, true) end
    elseif G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("footer", settings)
    end
end

---@param desktop table
local function refresh(desktop)
    refreshReaderUi()
    desktop:updateView()
end

---@param desktop table
---@param item BookReaderBarItem
---@param which string
---@return fun(width: number): table
local function itemRow(desktop, item, which)
    return function(iw)
        local index, align = Layout.slot(which, item.id)
        local enabled = index ~= nil
        local side = align == "right" and _("右") or _("左")
        return Row.widget({
    width = iw,
    chevron = true,
            kind = "nav",
            icon = item.icon,
            title = item.label,
            status = enabled and (side .. " · " .. T(_("第 %1 位"), index)) or _("关闭"),
            status_on = enabled,
            callback = function()
                --- 执行布局变更后刷新阅读页与设置页。
                ---@param change fun()
                ---@return fun()
                local function apply(change)
                    return function()
                        change()
                        refresh(desktop)
                    end
                end
                local actions = {{
                    text = enabled and _("停用") or _("启用"),
                    callback = apply(function() Layout.toggle(which, item.id) end),
                }}
                if enabled then
                    local count = #Layout.get(which)
                    actions[#actions + 1] = {
                        text = _("靠左"), enabled = align ~= "left",
                        callback = apply(function() Layout.setAlign(which, item.id, "left") end),
                    }
                    actions[#actions + 1] = {
                        text = _("靠右"), enabled = align ~= "right",
                        callback = apply(function() Layout.setAlign(which, item.id, "right") end),
                    }
                    actions[#actions + 1] = {
                        text = _("上移"), enabled = index > 1,
                        callback = apply(function() Layout.move(which, item.id, -1) end),
                    }
                    actions[#actions + 1] = {
                        text = _("下移"), enabled = index < count,
                        callback = apply(function() Layout.move(which, item.id, 1) end),
                    }
                    actions[#actions + 1] = Position.item(index, count, function(delta)
                        Layout.move(which, item.id, delta)
                        refresh(desktop)
                    end)
                end
                actions[#actions + 1] = { text = _("关闭") }
                Sheet:new{ title = item.label, items = actions }:show()
            end,
        })
    end
end

--- 顶栏或底栏组合页：预览 + 开关 + 组件。
---@param desktop table
---@param which string "top"|"bottom"
---@return { preview: fun(width: number): table, sections: table[] }
function ReaderBar:page(desktop, which)
    local replace_on = Layout.replace(which)
    local top = which == "top"
    local enabled = (top and Bars.topBarPreference or Bars.bottomBarPreference)()
    local replace_title = which == "top" and _("替代系统顶栏") or _("替代系统底栏")
    local enable_title = top and _("开启顶栏") or _("开启底栏")
    local enable_sub = top
        and _("跟随 KOReader 系统顶栏显示")
        or _("跟随 KOReader 系统底栏显示")
    local item_rows = {}
    for _idx, item in ipairs(Items.catalog(which)) do
        item_rows[#item_rows + 1] = itemRow(desktop, item, which)
    end
    local page = {
        preview = function(iw)
            return Preview.build(iw, which)
        end,
        sections = {
            {
                title = _("显示"),
                rows = {
                    function(iw)
                        return Row.widget({
    width = iw,
    chevron = false,
                            kind = "toggle",
                            icon = "layers",
                            title = replace_title,
                            subtitle = _("用月读栏覆盖系统栏；关闭后显示系统原栏"),
                            status = replace_on and _("开") or _("关"),
                            status_on = replace_on,
                            callback = function()
                                Layout.setReplace(which, not replace_on)
                                refresh(desktop)
                            end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
    width = iw,
    chevron = false,
                            kind = "toggle",
                            icon = which == "top" and "vertical_align_top" or "horizontal_rule",
                            title = enable_title,
                            subtitle = enable_sub,
                            status = enabled and _("开") or _("关"),
                            status_on = enabled,
                            callback = function()
                                (top and Bars.setTopBarPreference or Bars.setBottomBarPreference)(
                                    not enabled, readerUi())
                                refresh(desktop)
                            end,
                        })
                    end,
                    function(iw)
                        local icons_on = Layout.icons()
                        return Row.widget({
                            width = iw,
                            chevron = false,
                            kind = "toggle",
                            icon = "category",
                            title = _("组件图标"),
                            subtitle = _("电量、Wi-Fi、亮度等随状态换图标；顶栏底栏共用"),
                            status = icons_on and _("开") or _("关"),
                            status_on = icons_on,
                            callback = function()
                                Layout.setIcons(not icons_on)
                                refresh(desktop)
                            end,
                        })
                    end,
                    function(iw)
                        local size = Layout.fontSize(which, (footerSettings()))
                        local status = tostring(size)
                        if top and not Layout.topFontCustom() then
                            status = T(_("跟随底栏 · %1"), size)
                        end
                        return Row.widget({
                            width = iw,
                            kind = "nav",
                            icon = "format_size",
                            title = _("文字大小"),
                            subtitle = top and _("顶栏文字字号；未设置时跟随底栏")
                                or _("底栏文字字号，与 KOReader 状态栏同步"),
                            status = status,
                            status_on = true,
                            callback = function()
                                Spin:new{
                                    title = _("文字大小"),
                                    fields = { { value = size, min = Layout.FONT_MIN, max = Layout.FONT_MAX } },
                                    callback = function(v)
                                        Layout.setFontSize(which, v)
                                        if not top then writeFooterFont(v) end
                                        refresh(desktop)
                                    end,
                                }:show()
                            end,
                        })
                    end,
                },
            },
            {
                title = _("组件"),
                rows = item_rows,
            },
        },
    }
    if top then
        -- 顶栏高度：插在「组件图标」「文字大小」之后。
        table.insert(page.sections[1].rows, function(iw)
            local h = Layout.topHeight()
            return Row.widget({
                width = iw,
                kind = "nav",
                icon = "height",
                title = _("高度"),
                subtitle = _("顶栏比系统页头额外增加的高度"),
                status = tostring(h),
                status_on = true,
                callback = function()
                    Spin:new{
                        title = _("高度"),
                        fields = { { value = h, min = Layout.TOP_HEIGHT_MIN, max = Layout.TOP_HEIGHT_MAX, step = 2 } },
                        callback = function(v)
                            Layout.setTopHeight(v)
                            refresh(desktop)
                        end,
                    }:show()
                end,
            })
        end)
    end
    return page
end

return ReaderBar
