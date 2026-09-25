--[[--
阅读页顶栏 / 底栏组合页：替代系统栏、跟随系统开关、全宽预览、组件左右与顺序。

@module koplugin.book.ui.desktop.settings.reader_bar
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local SettingRow = require("ui.components.settingrow")
local Bars = require("ui.reader.bars")
local Items = require("ui.reader.bars.items")
local Layout = require("ui.reader.bars.layout")
local Preview = require("ui.reader.bars.preview")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsReaderBar
local ReaderBar = {}
---@return table|nil
local function readerUi()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance or nil
end

local function refreshReaderUi()
    local ui = readerUi()
    if ui and ui.dialog then
        UIManager:setDirty(ui.dialog, "ui")
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
        return SettingRow.build(iw, {
            kind = "nav",
            icon = item.icon,
            title = item.label,
            status = enabled and (side .. " · " .. T(_("第 %1 位"), index)) or _("关闭"),
            status_on = enabled,
            callback = function()
                local dialog
                local actions = {
                    {
                        {
                            text = enabled and _("停用") or _("启用"),
                            callback = function()
                                Layout.toggle(which, item.id)
                                UIManager:close(dialog)
                                refresh(desktop)
                            end,
                        },
                    },
                }
                if enabled then
                    actions[#actions + 1] = {
                        {
                            text = _("靠左"),
                            enabled = align ~= "left",
                            callback = function()
                                Layout.setAlign(which, item.id, "left")
                                UIManager:close(dialog)
                                refresh(desktop)
                            end,
                        },
                        {
                            text = _("靠右"),
                            enabled = align ~= "right",
                            callback = function()
                                Layout.setAlign(which, item.id, "right")
                                UIManager:close(dialog)
                                refresh(desktop)
                            end,
                        },
                    }
                    local count = #Layout.get(which)
                    actions[#actions + 1] = {
                        {
                            text = _("上移"),
                            enabled = index > 1,
                            callback = function()
                                Layout.move(which, item.id, -1)
                                UIManager:close(dialog)
                                refresh(desktop)
                            end,
                        },
                        {
                            text = _("下移"),
                            enabled = index < count,
                            callback = function()
                                Layout.move(which, item.id, 1)
                                UIManager:close(dialog)
                                refresh(desktop)
                            end,
                        },
                    }
                end
                actions[#actions + 1] = {{
                    text = _("关闭"),
                    callback = function() UIManager:close(dialog) end,
                }}
                dialog = ButtonDialog:new{
                    title = item.label,
                    title_align = "center",
                    use_info_style = false,
                    buttons = actions,
                }
                UIManager:show(dialog)
            end,
        })
    end
end

--- 顶栏或底栏组合页：预览 + 开关 + 组件。
---@param desktop table
---@param which string "top"|"bottom"
---@return { preview: fun(width: number): table, sections: BookQuickPanelSettingSection[] }
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
    for _, item in ipairs(Items.catalog(which)) do
        item_rows[#item_rows + 1] = itemRow(desktop, item, which)
    end
    return {
        preview = function(iw)
            return Preview.build(iw, which)
        end,
        sections = {
            {
                title = _("显示"),
                rows = {
                    function(iw)
                        return SettingRow.build(iw, {
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
                        return SettingRow.build(iw, {
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
                },
            },
            {
                title = _("组件"),
                rows = item_rows,
            },
        },
    }
end

return ReaderBar
