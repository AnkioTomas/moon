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

-- 成功：小段上下文，提示词带书名、选中词与正文；等待是进度窗，结果是弹窗卡片
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
Assert.is_nil(prompt:find("STORY SO FAR", 1, true), "不在任何章：不带前文摘要")
Assert.matches(requests[1].messages[1].content, "不要 Markdown")
Assert.matches(requests[1].messages[1].content, "不要输出思考过程")
Assert.eq(shown[1].kind, "progress_dialog")
Assert.eq(shown[1].title, "月色")
Assert.eq(shown[1].text, "AI 解释中…")
pending("  **月色**：这里指夜晚的月光。  ")
Assert.is_true(shown[1].closed)
Assert.eq(shown[2].kind, "text_viewer")
Assert.is_false(shown[2].fullscreen)
Assert.eq(shown[2].title, "月色")
Assert.eq(shown[2].text, "月色：这里指夜晚的月光。", "Markdown 标记剥掉")
Assert.len(shown[2].buttons, 2, "关闭走右上角 ×；选区已没了，不出存为笔记")
Assert.eq(shown[2].buttons[1].text, "追问")
Assert.eq(shown[2].buttons[2].text, "复制")
Assert.eq(clears, 0, "结果卡片还开着，选区留着")
shown[2]:close()
Assert.eq(clears, 1, "关掉结果卡片清选区")

-- 选区还在：可存为笔记，交给 KOReader 原生 addNote（建划线 + 预填笔记编辑框）
local noted
ui.highlight.selected_text = { text = "月色", pos0 = "a", pos1 = "b" }
ui.highlight.addNote = function(_hl, text) noted = text end
Explain.run(ui, { text = "月色" })
pending("夜晚的月光。")
local answer_card = shown[#shown]
Assert.len(answer_card.buttons, 3)
Assert.eq(answer_card.buttons[1].text, "存为笔记")
clears = 0
answer_card.buttons[1].callback()
Assert.is_true(answer_card.closed)
Assert.eq(noted, "夜晚的月光。")
Assert.eq(clears, 0, "存为笔记要用选区，由 addNote 自己清")

-- 追问：带上整条对话（含上一轮回答）再问；空问题不发
Explain.run(ui, { text = "月色" })
pending("夜晚的月光。")
answer_card = shown[#shown]
local before_followup = #requests
answer_card.buttons[2].callback()
local input = Themed.last("input")
Assert.eq(input.title, "追问")
input.callback("   ")
Assert.eq(#requests, before_followup, "空追问不发请求")
clears = 0
input.callback("为什么用月色？")
Assert.is_true(answer_card.closed)
Assert.eq(clears, 0, "追问的结果卡片接着用选区")
local chain = requests[#requests].messages
Assert.len(chain, 4)
Assert.eq(chain[3].role, "assistant")
Assert.eq(chain[3].content, "夜晚的月光。")
Assert.eq(chain[4].role, "user")
Assert.eq(chain[4].content, "为什么用月色？")
Assert.len(requests[#requests - 1].messages, 2, "上一轮的对话不被改写")
pending("营造清冷氛围。")
Assert.eq(shown[#shown].text, "营造清冷氛围。")
Assert.eq(shown[#shown].buttons[1].text, "存为笔记", "追问后的结果仍可存为笔记")
ui.highlight.selected_text = nil

-- 追问时断网：立即提示，不发请求
shown[#shown].buttons[2].callback()
connected = false
before_followup = #requests
Themed.last("input").callback("还有呢")
connected = true
Assert.eq(#requests, before_followup)
Assert.eq(shown[#shown].text, "网络不可用，请先连接 Wi-Fi")

-- 在第 4 章：提示词末尾带前三章的摘要
chapter_idx = 4
Explain.run(ui, { text = "月色" })
Assert.matches(requests[#requests].messages[2].content, "STORY SO FAR（前几章摘要）:\n第3章\n翠翠长大了。$")
pending("解释")
chapter_idx = nil

-- 失败：提示错误原因，清选区
Explain.run(ui, { text = "月色" })
clears = 0
pending(nil, "timeout")
Assert.eq(shown[#shown].kind, "toast")
Assert.matches(shown[#shown].text, "timeout")
Assert.eq(clears, 1)

-- 只剩 Markdown 空壳也算失败
Explain.run(ui, { text = "月色" })
pending("```\n```")
Assert.eq(shown[#shown].kind, "toast")

-- 等待窗：返回键关不掉，但有取消按钮；取消撤掉请求、清选区，迟到的回答不再出卡片
Explain.run(ui, { text = "月色" })
Assert.eq(shown[#shown].kind, "progress_dialog")
Assert.eq(shown[#shown].dismissable, false)
local shown_before = #shown
clears = 0
shown[#shown].on_cancel()
Assert.eq(cancelled, 1)
Assert.eq(clears, 1)
pending("收尾")
Assert.eq(#shown, shown_before)
cancelled = 0

-- 离线：立即提示，不发请求、不弹等待卡片
connected = false
local offline_before, offline_shown = #requests, #shown
Explain.run(ui, { text = "月色" })
connected = true
Assert.eq(#requests, offline_before)
Assert.eq(#shown, offline_shown + 1)
Assert.eq(shown[#shown].kind, "toast")
Assert.eq(shown[#shown].text, "网络不可用，请先连接 Wi-Fi")

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
