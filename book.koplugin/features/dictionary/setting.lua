--[[--
月读词典设置：开关、下载、管理。

@module koplugin.book.features.dictionary.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = { dictionary_enabled = true }

---@return table|nil
local function readerUi()
    return require("apps/reader/readerui").instance
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local MoonSettings = require("utils.settings")
    local on = MoonSettings.get("features.dictionary").dictionary_enabled
    return {
        {
            id = "main",
            group = "reader",
            order = 140,
            icon = "book",
            title = _("月读词典"),
            subtitle = _("管理词典"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("词典"),
                sections = function()
                    local current = MoonSettings.get("features.dictionary")
                    local enabled = current.dictionary_enabled
                    local rows = {
                        function(iw)
                            return require("ui.themes.widgets.row").widget({
                                width = iw,
                                chevron = false,
                                kind = "toggle",
                                icon = "book",
                                title = _("月读词典"),
                                status = enabled and _("开") or _("关"),
                                status_on = enabled,
                                callback = function()
                                    current.dictionary_enabled = not enabled
                                    MoonSettings.save("features.dictionary", current)
                                    desktop:updateView()
                                end,
                            })
                        end,
                    }
                    if enabled then
                        rows[#rows + 1] = function(iw)
                            return require("ui.themes.widgets.row").widget({
                                width = iw,
                                chevron = true,
                                kind = "nav",
                                icon = "cloud_download",
                                title = _("下载词典"),
                                callback = function()
                                    require("features.dictionary.ui").download(readerUi())
                                end,
                            })
                        end
                        rows[#rows + 1] = function(iw)
                            return require("ui.themes.widgets.row").widget({
                                width = iw,
                                chevron = true,
                                kind = "nav",
                                icon = "settings",
                                title = _("管理词典"),
                                callback = function()
                                    require("features.dictionary.ui").manage(readerUi())
                                end,
                            })
                        end
                    end
                    return { { title = _("词典"), rows = rows } }
                end,
            },
        },
    }
end

return Setting
