--[[--
AI 阅读助手设置：往「AI 接口」页追加「阅读助手」分节。

开关键归核心 `ai` 拥有（见 ai/setting.lua）：本 feature 的分区名末段也是 ai，会和它撞文件。

@module koplugin.book.features.ai.setting
--]]

local _ = require("gettext")

local Setting = {}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "ai",
            order = 10,
            sections = function()
                local MoonSettings = require("utils.settings")
                local Row = require("ui.themes.widgets.row")
                local cfg = MoonSettings.get("ai")
                ---@param key string
                ---@param icon string
                ---@param title string
                ---@param subtitle string
                ---@return fun(iw: number): table
                local function toggle(key, icon, title, subtitle)
                    return function(iw)
                        local on = cfg[key] == true
                        return Row.widget({
                            width = iw, chevron = false,
                            kind = "toggle", icon = icon, title = title, subtitle = subtitle,
                            status = on and _("开") or _("关"), status_on = on,
                            callback = function()
                                cfg[key] = not on
                                MoonSettings.save("ai", cfg)
                                if key == "ai_chapter_summary" and cfg[key] then
                                    local _count, err = require("features.ai.summary").resume()
                                    if err and err ~= "queue_full" then
                                        require("ui.themes.widgets.toast"):new{ text = err }:show()
                                    end
                                end
                                desktop:updateView()
                            end,
                        })
                    end
                end
                return {
                    {
                        title = _("阅读助手"),
                        rows = {
                            toggle("ai_chapter_summary", "summarize", _("读完章节自动生成摘要"),
                                _("顺读后后台生成，退出可续；长按「回顾前文」重试，会消耗 API 额度")),
                            toggle("ai_recap", "history", _("开书时显示前情提要"),
                                _("隔 3 天以上再读时显示最近几章摘要")),
                        },
                    },
                }
            end,
        },
    }
end

return Setting
