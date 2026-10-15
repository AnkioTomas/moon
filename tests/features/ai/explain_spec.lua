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
local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
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
local chapter_idx
local book_identity = { book = { title = "边城", authors = "沈从文" } }
package.preload["reader.session"] = function()
    return {
        current = function()
            return { identity = book_identity }
        end,
        chapterIndex = function() return chapter_idx end,
    }
end
package.preload["util"] = function()
    return { cleanupSelectedText = function(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end }
end

local configured = true
local requests, pending, cancelled = {}, nil, 0
local recap_chapters = 5
package.preload["ai"] = function()
    return {
        isConfigured = function() return configured end,
        priorSummaries = function(identity, idx, chapters)
            Assert.eq(identity, book_identity)
            Assert.eq(chapters, recap_chapters)
            return "第" .. idx - 1 .. "章\n翠翠长大了。"
        end,
        chat = function(messages, opts, cb)
            requests[#requests + 1] = { messages = messages, opts = opts }
            pending = cb
            return { cancel = function() cancelled = cancelled + 1 end }
        end,
    }
end

local actions = {}
package.preload["dispatcher"] = function()
    return { registerAction = function(_self, id, spec) actions[id] = spec end }
end

local recap_ready = 0
package.preload["features.ai.recap"] = function()
    return { onReaderReady = function() recap_ready = recap_ready + 1 end }
end

local Ai = require("features.ai")
local Explain = require("features.ai.explain")

-- 注册：阅读页就绪时挂进划词菜单，按钮键不变；AI 未配置时不显示
local factories = {}
local clears = 0
local ui = {
    highlight = {
        addToHighlightDialog = function(_, index, factory) factories[index] = factory end,
        clear = function() clears = clears + 1 end,
    },
}
Ai.onReaderReady({ ui = ui })
Assert.eq(recap_ready, 1, "开书时检查前情提要")
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

-- 划词 AI 解释：开多来源查词面板，停在「AI 释义」栏，带选区上下文
local looked_up
package.loaded["features.rare.lookup"] = { open = function(opts) looked_up = opts end }
button.callback()
Assert.is_true(closed_dialog)
Assert.eq(selected_pos, "/body/p[3]/text().4", "选区位置要交给上下文取段落")
Assert.eq(looked_up.source, "ai")
Assert.eq(looked_up.text, "月色")
Assert.is_true(looked_up.from_highlight)
Assert.eq(looked_up.context.sentence, "他望着那片月色。")
Assert.len(requests, 0, "AI 请求由面板切到该栏时才发")

-- 请求消息：小段上下文，提示词带书名、选中词、句子、段落与正文
ui.document = ui.document or {}
local messages = Explain.messages(ui, looked_up.context)
Assert.eq(context_limit, 2000)
local prompt = messages[2].content
Assert.matches(prompt, "《边城》（作者：沈从文）")
Assert.matches(prompt, "「月色」")
Assert.matches(prompt, "所在句子：\n他望着那片月色。")
Assert.matches(prompt, "所在段落：\n整段：他望着那片月色。")
Assert.matches(prompt, "前文若干")
Assert.is_nil(prompt:find("STORY SO FAR", 1, true), "不在任何章：不带前文摘要")
Assert.matches(messages[1].content, "不要 Markdown")
Assert.matches(messages[1].content, "不要输出思考过程")

-- 在第 4 章：提示词末尾带前三章的摘要
chapter_idx = 4
Assert.matches(Explain.messages(ui, looked_up.context)[2].content, "STORY SO FAR（前几章摘要）:\n第3章\n翠翠长大了。$")
chapter_idx = nil

-- 空选中不开面板，清选区
looked_up, clears = nil, 0
Explain.run(ui, { text = "   " })
Assert.is_nil(looked_up)
Assert.eq(clears, 1)

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

-- 问书：输入框提问，前文给得更宽（30 章摘要、6000 字节前文），回答卡片同划词解释
chapter_idx, recap_chapters = 4, 30
Explain.askBook(ui)
local ask_input = Themed.last("input")
Assert.eq(ask_input.title, "问书")
before = #requests
ask_input.callback("   ")
Assert.eq(#requests, before, "空问题不发")
ask_input.callback("翠翠的爷爷是做什么的？")
Assert.eq(context_limit, 6000)
local ask_prompt = requests[#requests].messages[2].content
Assert.matches(ask_prompt, "《边城》（作者：沈从文）")
Assert.matches(ask_prompt, "提了一个问题：\n翠翠的爷爷是做什么的？")
Assert.matches(ask_prompt, "不要透露后文")
Assert.matches(ask_prompt, "CURRENT PAGE:\n他望着那片月色")
Assert.matches(ask_prompt, "STORY SO FAR（前几章摘要）:\n第3章\n翠翠长大了。$")
Assert.eq(shown[#shown].title, "翠翠的爷爷是做什么的？")
pending("撑渡船。")
Assert.eq(shown[#shown].text, "撑渡船。")
Assert.len(shown[#shown].buttons, 2, "没有选区：只有追问、复制")
-- 问书不碰选区：即使阅读页还留着别的选区，也不出存为笔记、不清它
ui.highlight.selected_text = { text = "旧选区" }
clears = 0
Explain.askBook(ui)
Themed.last("input").callback("还有谁？")
pending("翠翠。")
Assert.len(shown[#shown].buttons, 2, "问书的回答不挂到旧选区上")
shown[#shown]:close()
Assert.eq(clears, 0)
ui.highlight.selected_text = nil
chapter_idx, recap_chapters = nil, 5

-- 问书离线：不弹输入框
connected = false
local inputs_before = #Themed.all("input")
Explain.askBook(ui)
connected = true
Assert.eq(#Themed.all("input"), inputs_before)
Assert.eq(shown[#shown].text, "网络不可用，请先连接 Wi-Fi")

-- 手势：登记 book_ai_ask；没文档不处理，未配置提示，配置好弹问书
Ai.onCreate()
Assert.eq(actions.book_ai_ask.event, "BookAiAsk")
Assert.is_true(actions.book_ai_ask.reader)
Assert.is_false(Ai.events.BookAiAsk({ ui = {} }))
ui.document = {}
configured = false
Assert.is_true(Ai.events.BookAiAsk({ ui = ui }))
Assert.eq(shown[#shown].text, "请先在月读设置中配置 AI 服务")
configured = true
Assert.is_true(Ai.events.BookAiAsk({ ui = ui }))
Assert.eq(Themed.last("input").title, "问书")
