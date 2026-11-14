--[[--
阅读页顶栏 / 底栏组合页：替代系统栏、跟随系统开关、全宽预览。
组件列表复用侧栏「页面顺序」的交互：图标、名称、设置、上移 / 下移；
专属设置（启用、对齐、进度小数、进度条粗细）收敛到对应组件页。

@module koplugin.book.features.bars.page
--]]

local UIManager = require("ui/uimanager")
local Overlay = require("desktop.pages.setting.overlay")
local Button = require("ui.themes.widgets.button")
local Row = require("ui.themes.widgets.row")
local Spin = require("ui.themes.widgets.spin")
local Theme = require("ui.themes")
local Bars = require("features.bars")
local Layout = require("features.bars.layout")
local Preview = require("features.bars.preview")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
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

--- 底栏边距就是 KOReader 状态栏的「Bottom margin」，写回去并让 footer 重排（正文随之让位）。
---@param v number
local function writeFooterBottomMargin(v)
    local settings, footer = footerSettings()
    if not settings then return end
    settings.container_bottom_padding = v
    if footer then
        footer.bottom_padding = require("device").screen:scaleBySize(v)
        footer:refreshFooter(true, true)
    elseif G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("footer", settings)
    end
end

---@param desktop table
local function refresh(desktop)
    local ui = readerUi()
    if ui then
        Bars.syncTopMargin(ui)
        Bars.syncBottomHeight(ui)
    end
    refreshReaderUi()
    desktop:updateView()
end

--- 组件专属设置页：启用 / 对齐，以及该组件自己的显示选项。
---@param desktop table
---@param which string
---@param item BookReaderBarItem
---@return BookSettingsOverlaySpec
function ReaderBar.itemPage(desktop, which, item)
    local function rows()
        local index, align = Layout.slot(which, item.id)
        local enabled = index ~= nil
        local out = {}
        out[#out + 1] = function(iw)
            return Row.widget({
                width = iw,
                chevron = false,
                kind = "toggle",
                icon = "visibility",
                title = _("启用"),
                subtitle = _("关闭后不在栏上显示"),
                status = enabled and _("开") or _("关"),
                status_on = enabled,
                callback = function()
                    Layout.toggle(which, item.id)
                    refresh(desktop)
                end,
            })
        end
        if enabled then
            out[#out + 1] = function(iw)
                return Row.choice({
                    width = iw,
                    icon = "align_horizontal_left",
                    title = _("对齐"),
                    items = {
                        { value = "left", text = _("靠左") },
                        { value = "center", text = _("居中") },
                        { value = "right", text = _("靠右") },
                    },
                    current = align or "left",
                    on_select = function(value)
                        Layout.setAlign(which, item.id, value)
                        refresh(desktop)
                    end,
                })
            end
            if which == "bottom" then
                local _index, _align, row = Layout.slot(which, item.id)
                out[#out + 1] = function(iw)
                    return Row.choice({
                        width = iw,
                        icon = "vertical_split",
                        title = _("所在行"),
                        subtitle = _("双栏时生效；单栏时所有组件仍在同一行，行归属会保留"),
                        items = {
                            { value = "up", text = _("上行") },
                            { value = "down", text = _("下行") },
                        },
                        current = row or "up",
                        on_select = function(value)
                            Layout.setRow(which, item.id, value)
                            refresh(desktop)
                        end,
                    })
                end
            end
        end
        if item.id == "percent" then
            out[#out + 1] = function(iw)
                local decimals_on = Layout.percentDecimals()
                return Row.widget({
                    width = iw,
                    chevron = false,
                    kind = "toggle",
                    icon = "percent",
                    title = _("总进度显示两位小数"),
                    subtitle = _("关闭时显示整数百分比"),
                    status = decimals_on and _("开") or _("关"),
                    status_on = decimals_on,
                    callback = function()
                        Layout.setPercentDecimals(not decimals_on)
                        refresh(desktop)
                    end,
                })
            end
        end
        if item.id == "progress_bar" then
            out[#out + 1] = function(iw)
                local own = Layout.progressThickness()
                local theme_h = Layout.themeProgressThickness()
                local value = own or theme_h
                local status = own and tostring(own) or T(_("跟随主题 · %1"), theme_h)
                return Row.widget({
                    width = iw,
                    kind = "nav",
                    icon = "horizontal_rule",
                    title = _("进度条粗细"),
                    subtitle = _("底栏进度条的厚度"),
                    status = status,
                    status_on = true,
                    callback = function()
                        Spin:new{
                            title = _("进度条粗细"),
                            fields = { {
                                value = value,
                                min = Layout.BAR_THICKNESS_MIN,
                                max = Layout.BAR_THICKNESS_MAX,
                            } },
                            callback = function(v)
                                Layout.setProgressThickness(v)
                                refresh(desktop)
                            end,
                        }:show()
                    end,
                })
            end
        end
        return out
    end
    return {
        title = item.label,
        preview = function(iw)
            return Preview.build(iw, which)
        end,
        sections = function()
            return { { title = _("显示"), rows = rows() } }
        end,
    }
end

--- 侧栏「页面顺序」同款：36px ghost 上移 / 下移，边界禁用，点一下即落盘并刷新。
---@param icon string
---@param enabled boolean
---@param callback fun()
---@return table
local function arrowButton(icon, enabled, callback)
    local size = Theme.px(36)
    return Button:new{
        icon = icon, variant = "ghost", width = size, height = size,
        enabled = enabled, callback = callback,
    }
end

---@param desktop table
---@param item BookReaderBarItem
---@param which string
---@return fun(width: number): table
local function itemRow(desktop, item, which)
    return function(iw)
        local index = Layout.slot(which, item.id)
        local enabled = index ~= nil
        local dual = which == "bottom" and Layout.stackedPreferred()
        local count = #Layout.get(which)
        local pos = index
        if dual and enabled then
            pos, count = Layout.rowPosition(which, item.id)
        end
        local function openSettings()
            Overlay.push(desktop, ReaderBar.itemPage(desktop, which, item))
        end
        local function shift(delta)
            if dual then
                Layout.moveInRow(which, item.id, delta)
            else
                Layout.move(which, item.id, delta)
            end
            refresh(desktop)
        end
        -- 右侧：设置图标 + 上移 + 下移（与侧栏页面顺序同一套按钮和间距）。
        -- 双栏时只在同一行内排序，不跨行。
        local trailing = HorizontalGroup:new{
            align = "center",
            arrowButton("settings", true, openSettings),
            HorizontalSpan:new{ width = Theme.px(4) },
            arrowButton("arrow_upward", enabled and pos and pos > 1, function()
                shift(-1)
            end),
            HorizontalSpan:new{ width = Theme.px(4) },
            arrowButton("arrow_downward", enabled and pos and pos < count, function()
                shift(1)
            end),
        }
        return Row.widget({
            width = iw,
            chevron = false,
            icon = item.icon,
            title = item.label,
            status = trailing,
            -- 点整行不改顺序，避免和右侧按钮抢手势；进设置只走设置图标。
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
    local function catalogRows(items)
        local out = {}
        for i = 1, #items do
            out[i] = itemRow(desktop, items[i], which)
        end
        return out
    end
    local item_rows = catalogRows(Layout.orderedCatalog(which))
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
                        local on = Layout.divider(which)
                        return Row.widget({
                            width = iw,
                            chevron = false,
                            kind = "toggle",
                            icon = "horizontal_rule",
                            title = _("分割线"),
                            subtitle = top and _("顶栏与正文之间画一条细线") or _("底栏与正文之间画一条细线"),
                            status = on and _("开") or _("关"),
                            status_on = on,
                            callback = function()
                                Layout.setDivider(which, not on)
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
    if not top and Layout.stackedPreferred() then
        -- 双栏：上下行各自一段列表，各自排序；未启用的单独一段。
        local up, down, unused = {}, {}, {}
        for _idx, item in ipairs(Layout.orderedCatalog(which)) do
            local index, _align, row = Layout.slot(which, item.id)
            if not index then
                unused[#unused + 1] = item
            elseif row == "down" then
                down[#down + 1] = item
            else
                up[#up + 1] = item
            end
        end
        page.sections[2] = { title = _("上行"), rows = catalogRows(up) }
        page.sections[3] = { title = _("下行"), rows = catalogRows(down) }
        if #unused > 0 then
            page.sections[4] = { title = _("未启用"), rows = catalogRows(unused) }
        end
    end
    if not top then
        -- 底栏单栏 / 双栏是显式布局，不随组件居中自动拆行。
        table.insert(page.sections[1].rows, 3, function(iw)
            local stacked = Layout.stackedPreferred()
            return Row.choice({
                width = iw,
                icon = "view_agenda",
                title = _("布局"),
                subtitle = _("双栏时每个组件可放在上行或下行，空行不留白"),
                items = {
                    { value = "single", text = _("单栏") },
                    { value = "double", text = _("双栏") },
                },
                current = stacked and "double" or "single",
                on_select = function(value)
                    Layout.setStacked(value == "double")
                    refresh(desktop)
                end,
            })
        end)
    end
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
    table.insert(page.sections[1].rows, function(iw)
        local m = top and Layout.topMargin() or Layout.bottomMargin((footerSettings()))
        return Row.widget({
            width = iw,
            kind = "nav",
            icon = top and "vertical_align_top" or "vertical_align_bottom",
            title = _("边距"),
            subtitle = top and _("顶栏离屏幕顶部的距离，正文随之下移")
                or _("底栏离屏幕底部的距离，与 KOReader 状态栏「Bottom margin」同步"),
            status = tostring(m),
            status_on = true,
            callback = function()
                Spin:new{
                    title = _("边距"),
                    fields = { {
                        value = m,
                        min = top and Layout.TOP_MARGIN_MIN or Layout.BOTTOM_MARGIN_MIN,
                        max = top and Layout.TOP_MARGIN_MAX or Layout.BOTTOM_MARGIN_MAX,
                    } },
                    callback = function(v)
                        if top then Layout.setTopMargin(v) else writeFooterBottomMargin(v) end
                        refresh(desktop)
                    end,
                }:show()
            end,
        })
    end)
    return page
end

return ReaderBar
