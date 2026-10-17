--[[--
月读词典设置：往桌面「划词与查询」页追加「词典」分节（开关、下载、管理）。

@module koplugin.book.features.dictionary.setting
--]]

local _ = require("gettext")

local Setting = {}

-- dictionary_load_all：查词面板列出全部已安装词典（含已停用、无结果的），可自行切换。
Setting.defaults = { dictionary_enabled = true, dictionary_load_all = true }

--- 桌面开在文件管理器上（阅读器已关），它也挂着一份 ReaderDictionary；
--- 必须用真实实例，安装 / 切换后才能刷新 KOReader 的词典缓存与 sdcv 参数。
---@return table
local function hostUi()
    return require("apps/reader/readerui").instance
        or require("apps/filemanager/filemanager").instance
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "lookup",
            order = 50,
            sections = function()
                local MoonSettings = require("utils.settings")
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
                        local on = current.dictionary_load_all
                        return require("ui.themes.widgets.row").widget({
                            width = iw,
                            chevron = false,
                            kind = "toggle",
                            icon = "book",
                            title = _("加载所有词典"),
                            subtitle = _("无论是否启用、有无结果，都列在查词菜单里供切换"),
                            status = on and _("开") or _("关"),
                            status_on = on,
                            callback = function()
                                current.dictionary_load_all = not on
                                MoonSettings.save("features.dictionary", current)
                                desktop:updateView()
                            end,
                        })
                    end
                    rows[#rows + 1] = function(iw)
                        return require("ui.themes.widgets.row").widget({
                            width = iw,
                            chevron = true,
                            kind = "nav",
                            icon = "cloud_download",
                            title = _("下载词典"),
                            callback = function()
                                require("features.dictionary.ui").download(hostUi())
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
                                require("features.dictionary.ui").manage(hostUi())
                            end,
                        })
                    end
                end
                return { { title = _("词典"), rows = rows } }
            end,
        },
    }
end

return Setting
