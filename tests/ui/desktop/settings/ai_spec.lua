--[[-- AI 服务设置项离线用例：测试连接行。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, value) return value end }
end

local shown = {}
local closed = {}
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget) closed[#closed + 1] = widget end,
    }
end

local built
package.preload["ui.components.settingrow"] = function()
    return { build = function(_width, value) built = value; return value end }
end

local settings = { ai_endpoint = "", ai_api_key = "", ai_model = "" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end, saveSection = function() end }
end

package.preload["ffi/util"] = function()
    return { template = function(fmt, value) return (fmt:gsub("%%1", tostring(value))) end }
end

local ai_configured = true
local chat_calls = {}
package.preload["ai"] = function()
    return {
        isConfigured = function() return ai_configured end,
        chat = function(messages, opts, cb)
            chat_calls[#chat_calls + 1] = { messages = messages, opts = opts }
            chat_calls[#chat_calls].cb = cb
        end,
    }
end

local AI = require("ui.desktop.settings.ai")
local desktop = { rebuild = function() end, _closed = false }
local rows = AI.rows(desktop)
Assert.len(rows, 4)

-- 第 4 行是测试连接
rows[4](400)
Assert.eq(built.title, "测试连接")
Assert.eq(built.icon, "network_check")
Assert.eq(built.kind, "action")

-- 未配置：提示配置，不发请求
ai_configured = false
shown = {}
built.callback()
Assert.len(chat_calls, 0)
Assert.eq(shown[#shown].text, "请先配置接口地址、API 密钥和模型")

-- 已配置：发出最小 chat，loading 持续到回调返回
ai_configured = true
shown = {}
closed = {}
built.callback()
Assert.len(chat_calls, 1)
Assert.eq(chat_calls[1].opts.max_tokens, 10)
Assert.eq(chat_calls[1].opts.timeout, 30)
Assert.eq(shown[#shown].text, "正在测试…")
Assert.is_nil(shown[#shown].timeout)
Assert.len(closed, 0)
chat_calls[1].cb("pong 你好世界")
Assert.len(closed, 1)
Assert.eq(closed[1].text, "正在测试…")
Assert.eq(shown[#shown].text, "连接正常，模型回复：pong 你好世界")

-- 在途时重复点击不发第二次（新发起一轮再点）
built.callback()
Assert.len(chat_calls, 2)
built.callback()
Assert.len(chat_calls, 2)

-- 失败路径显示错误
chat_calls[2].cb(nil, "401 bad key")
Assert.eq(shown[#shown].text, "测试失败：401 bad key")

-- 桌面已关闭：关闭 loading，结果回调不再弹窗
shown = {}
closed = {}
desktop._closed = true
built.callback()
Assert.len(chat_calls, 3)
chat_calls[3].cb("late")
Assert.len(closed, 1)
Assert.eq(closed[1].text, "正在测试…")
Assert.len(shown, 1)  -- 只有“正在测试…”，结果被吞掉
