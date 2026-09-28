--[[-- ui.reader.explain：划词 AI 解释的注册、请求拼装、展示与取消。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a) return (fmt:gsub("%%1", tostring(a))) end }
end

local shown, closed = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget)
            closed[#closed + 1] = widget
            if widget.dismiss_callback then widget.dismiss_callback() end
        end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) opts.kind = "info"; return opts end }
end
package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, opts) opts.kind = "viewer"; return opts end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, callback) callback() end }
end
local context_limit
package.preload["xray.context"] = function()
    return {
        forAnalysis = function(ui, limit)
            context_limit = limit
            return { current_page = "他望着那片月色", prior_text = "前文若干", page = 3 }
        end,
    }
end
package.preload["ui.reader.session"] = function()
    return {
        current = function()
            return { identity = { book = { title = "边城", authors = "沈从文" } } }
        end,
    }
end
package.preload["util"] = function()
    return { cleanupSelectedText = function(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end }
end

local configured = true
local requests, pending, cancelled = {}, nil, 0
package.preload["ai"] = function()
    return {
        isConfigured = function() return configured end,
        chat = function(messages, opts, cb)
            requests[#requests + 1] = { messages = messages, opts = opts }
            pending = cb
            return { cancel = function() cancelled = cancelled + 1 end }
        end,
    }
end

local Explain = require("ui.reader.explain")

-- 注册：只装一次，AI 未配置时不显示
local factories = {}
local ui = {
    highlight = {
        addToHighlightDialog = function(_, index, factory) factories[index] = factory end,
    },
}
Explain.install(ui)
Explain.install(ui)
local closed_dialog = false
local this = {
    ui = ui,
    selected_text = { text = "  月色  " },
    onClose = function() closed_dialog = true end,
}
local button = factories["12_ai_explain"](this)
Assert.eq(button.text, "AI 解释")
Assert.is_true(button.show_in_highlight_dialog_func())
configured = false
Assert.is_false(button.show_in_highlight_dialog_func())
configured = true

-- 成功：小段上下文，提示词带书名、选中词与正文，结果进 TextViewer
button.callback()
Assert.is_true(closed_dialog)
Assert.eq(context_limit, 2000)
Assert.len(requests, 1)
local prompt = requests[1].messages[2].content
Assert.matches(prompt, "《边城》（作者：沈从文）")
Assert.matches(prompt, "「月色」")
Assert.matches(prompt, "他望着那片月色")
Assert.matches(prompt, "前文若干")
Assert.eq(shown[1].text, "AI 解释中…")
pending("  这里指夜晚的月光。  ")
Assert.eq(closed[1], shown[1])
Assert.eq(cancelled, 0, "请求完成后关提示不得再取消")
Assert.eq(shown[2].kind, "viewer")
Assert.eq(shown[2].title, "月色")
Assert.eq(shown[2].text, "这里指夜晚的月光。")

-- 失败：提示错误原因
Explain.run(ui, "月色")
pending(nil, "timeout")
Assert.eq(shown[4].kind, "info")
Assert.matches(shown[4].text, "timeout")

-- 用户关掉等待提示：取消请求
Explain.run(ui, "月色")
shown[#shown].dismiss_callback()
Assert.eq(cancelled, 1)

-- 空选中不发请求
local before = #requests
Explain.run(ui, "   ")
Assert.eq(#requests, before)
