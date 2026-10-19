--[[--
文字识别设置：往桌面「查词」页追加「文字识别（OCR）」分节（下载、管理、说明），排在词典之后。

@module koplugin.book.features.ocr.setting
--]]

local _ = require("gettext")

local Setting = {}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "lookup",
            order = 55,
            sections = function()
                local Row = require("ui.themes.widgets.row")
                local Manager = require("features.ocr.manager")
                local count = #Manager.installed(Manager.dataDir())
                local forced = Manager.forcedOcr()
                local rows = {
                    function(iw)
                        return Row.widget({
                            width = iw,
                            chevron = false,
                            kind = "toggle",
                            icon = "document_scanner",
                            title = _("强制文字识别"),
                            subtitle = _("即 KOReader「Forced OCR」：有文字层的 PDF 也改用识别；扫描页不开也会识别"),
                            status = forced and _("开") or _("关"),
                            status_on = forced,
                            callback = function()
                                Manager.setForcedOcr(not forced)
                                desktop:updateView()
                            end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw,
                            chevron = true,
                            kind = "nav",
                            icon = "cloud_download",
                            title = _("下载识别语言"),
                            subtitle = _("仅对扫描版 PDF / DjVu 生效，长按文字即可识别"),
                            callback = function() require("features.ocr.ui").download() end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw,
                            chevron = true,
                            kind = "nav",
                            icon = "settings",
                            title = _("管理识别语言"),
                            status = count > 0 and tostring(count) or _("未安装"),
                            callback = function() require("features.ocr.ui").manage() end,
                        })
                    end,
                }
                return { { title = _("文字识别（OCR）"), rows = rows } }
            end,
        },
    }
end

return Setting
