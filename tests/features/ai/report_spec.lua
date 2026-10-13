---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- features.ai.report：报告存 summary_db.extra；提示词；AI 失败；离线；已有报告卡片。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local shown = {}
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) shown[#shown + 1] = o end

local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
package.preload["device"] = function()
    return { input = { setClipboardText = function() end } }
end

local chat_calls = {}
package.preload["ai"] = function()
    return {
        chat = function(messages, opts, cb)
            chat_calls[#chat_calls + 1] = { messages = messages, opts = opts, cb = cb }
            return { cancel = function() end }
        end,
    }
end

local db_report
package.preload["ai.summary_db"] = function()
    return {
        upTo = function(source_id, stable_id, _max_idx, limit)
            Assert.eq(source_id, "wechat")
            Assert.eq(stable_id, "b1")
            Assert.eq(limit, 200)
            return {
                { chapter_idx = 1, title = "第一章", summary = "他出发了。" },
                { chapter_idx = 2, title = "", summary = "他到了。" },
            }
        end,
        report = function() return db_report end,
        putReport = function(_source_id, _stable_id, text)
            db_report = text
            return true
        end,
    }
end
package.preload["book.note_db"] = function()
    return { all = function()
        return { { payload = "p1" }, { payload = "p2" } }
    end }
end
package.preload["book.note.normalize"] = function()
    return { decode = function(payload)
        if payload == "p1" then
            return { { drawer = "lighten", text = "  人生如逆旅  ", note = "喜欢" }, { text = "书签，不算" } }
        end
        return { { drawer = "underscore", text = "我亦是行人" } }
    end }
end
package.preload["book.stats_db"] = function()
    return { summaryByBook = function()
        return { total_seconds = 7260, pages = 321, last_read = 0 }
    end }
end

local started
package.preload["workers.ui.task_dialog"] = function()
    return { start = function(spec)
        started = spec
        return true
    end }
end

local identity = { source_id = "wechat", stable_id = "b1", book = { title = "临江仙", authors = "苏轼" } }
local session = { identity = identity, percent = 42.4 }
package.preload["reader.session"] = function()
    return { current = function() return session end }
end

-- 书里能定位到的句子 → xpointer 区间
local IN_BOOK = { ["人生如逆旅"] = { "/p[1].0", "/p[1].5" }, ["我亦是行人"] = { "/p[2].0", "/p[2].5" } }
package.preload["reader.session.derived_note"] = function()
    return { locate = function(_document, text)
        local hit = IN_BOOK[text]
        if hit then return hit[1], hit[2] end
    end }
end
package.preload["ui/event"] = function()
    return { new = function(_self, name, args) return { name = name, args = args } end }
end
local dirty = 0
package.preload["ui/uimanager"] = function()
    return { setDirty = function() dirty = dirty + 1 end }
end

local events = {}
local ui = {
    rolling = true,
    document = { getTextFromXPointers = function(_self, pos0)
        return pos0 == "/p[1].0" and " 人生如逆旅 " or "我亦是行人"
    end },
    annotation = { annotations = {} },
    toc = { getTocTitleByPage = function() return "第一章" end },
    view = { highlight = { saved_drawer = "lighten", saved_color = "yellow" } },
    handleEvent = function(_self, event) events[#events + 1] = event end,
}
ui.dialog = ui
function ui.annotation:addItem(item)
    self.annotations[#self.annotations + 1] = item
    return #self.annotations
end

local Report = require("features.ai.report")

---@param s string
---@param needle string
local function has(s, needle)
    Assert.is_true(s:find(needle, 1, true) ~= nil, needle)
end

---@param spec table
---@param answer string|nil
---@param err string|nil
---@return table
local function finish(spec, answer, err)
    local result
    spec.run(function() end, function(r) result = r end)
    chat_calls[#chat_calls].cb(answer, err)
    spec.on_done(result)
    return result
end

-- 提示词：书名作者、进度、统计、章节摘要、只收划线
local content = Report.messages(identity, 42.4)[2].content
has(content, "《临江仙》（作者：苏轼）")
has(content, "约 42%")
has(content, "累计阅读 121 分钟，翻过 321 页")
has(content, "第一章：他出发了。\n#2：他到了。")
has(content, "「人生如逆旅」　笔记：喜欢\n「我亦是行人」")
Assert.is_nil(content:find("书签，不算", 1, true))
has(content, "必须是书中原文")

-- 金句只取第四节的「」
local REPORT = "一、讲「旅途」\n四、值得回味的句子\n• 「人生如逆旅」\n• 「 我亦是行人 」\n• 「不在书里」\n"
    .. "五、延伸阅读\n• 「别的书」"
Assert.eq(table.concat(Report.quotes(REPORT), "|"), "人生如逆旅|我亦是行人|不在书里")
Assert.eq(table.concat(Report.quotes("四、\n「最后一节」"), "|"), "最后一节")
Assert.len(Report.quotes("没有分节"), 0)

-- AI 失败：提示且不写
Report.open(ui)
Assert.eq(started.key, "ai_report\0wechat\0b1")
Assert.eq(started.kind, "cache")
Assert.is_true(started.restartable)
local result = finish(started, nil, "超时")
Assert.eq(result.ok, false)
Assert.is_nil(db_report)
Assert.eq(shown[#shown].kind, "toast")
has(shown[#shown].text, "超时")

-- 没有报告：生成 → 写进 summary_db.extra → 弹卡片；没有金句不出高亮按钮
Report.open(ui)
result = finish(started, "  一、好书  ")
Assert.is_true(result.ok)
Assert.eq(db_report, "一、好书")
Assert.eq(shown[#shown].kind, "text_viewer")
Assert.eq(shown[#shown].text, "一、好书")
Assert.len(shown[#shown].buttons, 2)

-- 已有报告：直接展示，不再请求；有金句出「高亮金句」
db_report = REPORT
started = nil
Report.open(ui)
Assert.is_nil(started)
local card = shown[#shown]
Assert.eq(card.text, REPORT)
Assert.eq(card.buttons[2].text, "高亮金句")

-- 高亮：找到的加划线（文字取书中原文、带章节与默认样式、datetime 错开），找不到的计数
card.buttons[2].callback()
Assert.len(ui.annotation.annotations, 2)
local first, second = ui.annotation.annotations[1], ui.annotation.annotations[2]
Assert.eq(first.pos0, "/p[1].0")
Assert.eq(first.text, "人生如逆旅")
Assert.eq(first.drawer, "lighten")
Assert.eq(first.color, "yellow")
Assert.eq(first.chapter, "第一章")
Assert.is_true(first.datetime ~= second.datetime)
Assert.len(events, 2)
Assert.eq(events[1].name, "AnnotationsModified")
Assert.eq(events[1].args.nb_highlights_added, 1)
Assert.eq(dirty, 1)
Assert.eq(shown[#shown].text, "已高亮 2 句，1 句在书中没找到")

-- 再点一次：已有划线跳过，不重复加
card.buttons[2].callback()
Assert.len(ui.annotation.annotations, 2)
Assert.eq(shown[#shown].text, "已高亮 0 句，2 句已有划线，1 句在书中没找到")

-- 书已关 / 非 CREngine 文档：不出高亮按钮
ui.rolling = false
Report.open(ui)
Assert.len(shown[#shown].buttons, 2)
ui.rolling = true
Report.open(ui)

-- 离线点重新生成：立即提示，不入队
connected = false
shown[#shown].buttons[1].callback()
Assert.is_nil(started)
Assert.eq(shown[#shown].text, "网络不可用，请先连接 Wi-Fi")
