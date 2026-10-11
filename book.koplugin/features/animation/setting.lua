--[[--
翻页动画设置：开关（装/卸补丁）与风格。

@module koplugin.book.features.animation.setting
--]]

local _ = require("gettext")

local Setting = {}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local Animation = require("features.animation")
    local on = Animation.isEnabled()
    return {
        {
            id = "main",
            group = "reader",
            order = 130,
            icon = "animation",
            title = _("翻页动画"),
            subtitle = _("软件翻页过渡与风格"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("翻页动画"),
                sections = function()
                    local Row = require("ui.themes.widgets.row")
                    local enabled = Animation.isEnabled()
                    local rows = {
                        function(iw)
                            return Row.widget({
                                width = iw,
                                chevron = false,
                                kind = "toggle",
                                icon = "animation",
                                title = _("翻页动画"),
                                status = enabled and _("开") or _("关"),
                                status_on = enabled,
                                callback = function()
                                    local res = Animation.setEnabled(not enabled)
                                    if not res.ok then
                                        require("ui.themes.widgets.toast"):new{
                                            text = require("ffi/util").template(
                                                _("翻页动画补丁操作失败：%1"), tostring(res.err or "")),
                                            timeout = 3,
                                        }:show()
                                        return
                                    end
                                    desktop:updateView()
                                    Animation.promptRestart()
                                end,
                            })
                        end,
                    }
                    if enabled then
                        rows[#rows + 1] = function(iw)
                            return Row.widget({
                                width = iw,
                                chevron = true,
                                kind = "nav",
                                icon = "animation",
                                title = _("翻页动画风格"),
                                status = Animation.currentStyle().text,
                                callback = function()
                                    Animation.pickStyle(function() desktop:updateView() end)
                                end,
                            })
                        end
                    end
                    return { { title = _("翻页动画"), rows = rows } }
                end,
            },
        },
    }
end

return Setting
