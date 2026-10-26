--[[--
翻页动画设置：开关装/卸补丁，选择风格与速度。

@module koplugin.book.features.animation.setting
--]]

local _ = require("gettext")

local Setting = {}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "reader",
            order = 11,
            icon = "animation",
            title = _("翻页动画"),
            subtitle = _("开关、动画风格与速度"),
            page = {
                title = _("翻页动画"),
                sections = function()
                    local Animation = require("features.animation")
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
                                                _("翻页动画补丁操作失败：%1"), res.err),
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
                                title = _("翻页动画速度"),
                                status = Animation.currentSpeed().text,
                                callback = function()
                                    Animation.pickSpeed(function() desktop:updateView() end)
                                end,
                            })
                        end
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
