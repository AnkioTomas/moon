--[[-- AI 服务设置项。
@module koplugin.book.desktop.pages.setting.ai
--]]

require("l10n").apply()

local Input = require("ui.themes.widgets.input")
local Toast = require("ui.themes.widgets.toast")
local Row = require("ui.themes.widgets.row")
local Settings = require("utils.settings")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

---@class BookSettingsAI
local AI = {}

--- 弹输入框编辑一项 AI 配置，保存后写入 ai 分区并重建桌面。
---@param desktop table 桌面实例
---@param key string ai 配置键名
---@param title string 对话框标题，也是设置行标题
---@param hint string 输入框占位提示
---@param password boolean 是否按密码遮蔽输入
---@param normalize fun(value: string): string 落盘前的规范化（去空白、去尾斜杠等）
local function edit(desktop, key, title, hint, password, normalize)
    local cfg = Settings.get("ai")
    Input:new{
        title = title,
        fields = { { text = tostring(cfg[key] or ""), hint = hint, text_type = password and "password" or nil } },
        ok_text = _("保存"),
        callback = function(value)
            cfg[key] = normalize(value)
            Settings.save("ai", cfg)
            desktop:updateView()
        end,
    }:show()
end

--- 造一个 AI 配置项设置行的构造器；密码项状态只显示星号。
---@param desktop table 桌面实例
---@param key string ai 配置键名
---@param title string 设置行标题
---@param hint string 输入框占位提示
---@param password boolean 是否按密码遮蔽
---@param normalize fun(value: string): string 落盘前的规范化
---@return fun(iw: number): table
local function row(desktop, key, title, hint, password, normalize)
    return function(iw)
        local value = Settings.get("ai")[key] or ""
        local status = value ~= "" and (password and "******" or value) or _("未设置")
        return Row.widget({
            width = iw,
            kind = "nav", icon = password and "key" or "edit", title = title,
            status = status, status_on = value ~= "", callback = function()
                edit(desktop, key, title, hint, password, normalize)
            end,
        })
    end
end

--- 点按后发一条最小 chat（小 max_tokens），成功显示返回摘要，失败显示错误。
---@param desktop table
---@return function
local function testRow(desktop)
    return function(iw)
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "action", icon = "network_check", title = _("测试连接"),
            callback = function()
                if not require("ai").isConfigured() then
                    Toast:new{ text = _("请先配置接口地址、API 密钥和模型"), timeout = 2 }:show()
                    return
                end
                local loading = require("ui.themes.widgets.progress_dialog"):new{
                    title = _("测试连接"), text = _("正在测试…"), dismissable = false,
                }
                loading:show()
                require("ai").chat({ { role = "user", content = "ping" } },
                    { max_tokens = 64 },
                    function(content, err)
                        loading:close()
                        if desktop.closed then
                            return
                        end
                        local text
                        if content then
                            text = T(_("连接正常，模型回复：%1"), Text.trim(content):sub(1, 50))
                        else
                            text = T(_("测试失败：%1"), tostring(err))
                        end
                        Toast:new{ text = text, timeout = 4 }:show()
                    end)
            end,
        })
    end
end

--- 「AI 请求超时」：AI 默认秒数，各功能按倍率 × 它（见 http/timeout.lua）。
---@param desktop table
---@return function
local function timeoutRow(desktop)
    return function(iw)
        local Timeout = require("http.timeout")
        local value = Timeout.aiSeconds()
        return Row.widget({
            width = iw,
            kind = "nav", icon = "timer", title = _("AI 请求超时"),
            subtitle = T(_("等待模型回复的最长时间；报告、X-Ray 按倍率更长（%1 秒）"), Timeout.ai(1.5)),
            status = T(_("%1 秒"), value), status_on = true,
            callback = function()
                require("ui.themes.widgets.spin"):new{
                    title = _("AI 请求超时"),
                    fields = { { value = value, min = Timeout.AI_MIN, max = Timeout.AI_MAX, step = Timeout.AI_STEP,
                        format = function(v) return T(_("%1 秒"), v) end } },
                    callback = function(v)
                        Timeout.setAiSeconds(v)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
end

---@param desktop table
---@return table
function AI:rows(desktop)
    return {
        row(desktop, "ai_endpoint", _("接口地址"), "https://api.example.com/v1", false,
            function(value) return Text.rtrimSlashes(Text.trim(value)) end),
        row(desktop, "ai_api_key", _("API 密钥"), _("输入 API 密钥"), true,
            function(value) return Text.trim(value) end),
        row(desktop, "ai_model", _("模型"), _("输入模型名"), false,
            function(value) return Text.trim(value) end),
        timeoutRow(desktop),
        testRow(desktop),
    }
end

return AI
