---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- features.ai：划词 AI 解释的注册、请求拼装、纯文本清洗、弹窗展示与取消。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a) return (fmt:gsub("%%1", tostring(a))) end }
end

local shown = {}
package.preload["ui/uimanager"] = function() return {} end
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) shown[#shown + 1] = o end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, callback) callback() end }
end
local context_limit, selected_pos
package.preload["reader.context"] = function()
    return {
        forAnalysis = function(ui, limit)
            context_limit = limit
            return { current_page = "他望着那片月色", prior_text = "前文若干", page = 3 }
        end,
        selection = function(ui, selected)
            selected_pos = selected.pos0
            local text = selected.text:gsub("^%s+", ""):gsub("%s+$", "")
            return { text = text, sentence = "他望着那片" .. text .. "。", paragraph = "整段：他望着那片" .. text .. "。" }
        end,
    }
end
package.preload["reader.session"] = function()
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

local Ai = require("features.ai")
local Explain = require("features.ai.explain")

-- 注册：阅读页就绪时挂进划词菜单，按钮键不变；AI 未配置时不显示
local factories = {}
local ui = {
    highlight = {
        addToHighlightDialog = function(_, index, factory) factories[index] = factory end,
    },
}
Ai.onReaderReady({ ui = ui })
local closed_dialog = false
local this = {
    ui = ui,
    selected_text = { text = "  月色  ", pos0 = "/body/p[3]/text().4" },
    onClose = function() closed_dialog = true end,
}
local button = factories["12_ai_explain"](this)
Assert.eq(button.text, "AI 解释")
Assert.is_true(button.show_in_highlight_dialog_func())
configured = false
Assert.is_false(button.show_in_highlight_dialog_func())
configured = true

-- 成功：小段上下文，提示词带书名、选中词与正文；等待和结果都是弹窗卡片
button.callback()
Assert.is_true(closed_dialog)
Assert.eq(context_limit, 2000)
Assert.len(requests, 1)
local prompt = requests[1].messages[2].content
Assert.matches(prompt, "《边城》（作者：沈从文）")
Assert.eq(selected_pos, "/body/p[3]/text().4", "选区位置要交给上下文取段落")
Assert.matches(prompt, "「月色」")
Assert.matches(prompt, "所在句子：\n他望着那片月色。")
Assert.matches(prompt, "所在段落：\n整段：他望着那片月色。")
Assert.matches(prompt, "前文若干")
Assert.matches(requests[1].messages[1].content, "不要 Markdown")
Assert.matches(requests[1].messages[1].content, "不要输出思考过程")
Assert.eq(shown[1].kind, "text_viewer")
Assert.is_false(shown[1].fullscreen)
Assert.eq(shown[1].title, "月色")
Assert.eq(shown[1].text, "AI 解释中…")
pending("  **月色**：这里指夜晚的月光。  ")
Assert.is_true(shown[1].closed)
Assert.eq(cancelled, 0, "请求完成后关等待弹窗不得再取消")
Assert.eq(shown[2].kind, "text_viewer")
Assert.is_false(shown[2].fullscreen)
Assert.eq(shown[2].title, "月色")
Assert.eq(shown[2].text, "月色：这里指夜晚的月光。", "Markdown 标记剥掉")
Assert.len(shown[2].buttons, 1, "关闭走右上角 ×，底栏只留复制")
Assert.eq(shown[2].buttons[1].text, "复制")

-- 失败：提示错误原因
Explain.run(ui, { text = "月色" })
pending(nil, "timeout")
Assert.eq(shown[4].kind, "toast")
Assert.matches(shown[4].text, "timeout")

-- 只剩 Markdown 空壳也算失败
Explain.run(ui, { text = "月色" })
pending("```\n```")
Assert.eq(shown[#shown].kind, "toast")

-- 用户关掉等待弹窗：取消请求
Explain.run(ui, { text = "月色" })
shown[#shown]:close()
Assert.eq(cancelled, 1)

-- 空选中不发请求
local before = #requests
Explain.run(ui, { text = "   " })
Assert.eq(#requests, before)

-- 纯文本清洗：标题、加粗、斜体、行内代码、代码块、引用、分隔线、链接去掉，列表符号换成圆点
Assert.eq(Explain.plain(table.concat({
    "## 释义",
    "**月色**指*月光*，见`古诗`。",
    "```text",
    "代码",
    "```",
    "> 引文",
    "---",
    "  - 第一点",
    "* 第二点",
    "参见[词典](https://example.com)。",
    "",
    "",
    "",
    "结尾",
}, "\n")), table.concat({
    "释义",
    "月色指月光，见古诗。",
    "代码",
    "引文",
    "• 第一点",
    "• 第二点",
    "参见词典。",
    "",
    "结尾",
}, "\n"))
Assert.eq(Explain.plain("3 * 4 = 12，纯文本不动"), "3 * 4 = 12，纯文本不动")
