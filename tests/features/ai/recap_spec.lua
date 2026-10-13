---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- features.ai.recap：隔 3 天开书自动弹、手动打开无摘要提示；面板动作。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local shown = {}
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_self, fn) fn() end }
end
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) shown[#shown + 1] = o end
package.preload["ui.guard"] = function()
    return { wrap = function(_label, fn) return fn end }
end

local cfg = { ai_recap = true }
package.preload["utils.settings"] = function()
    return { get = function(owner)
        assert(owner == "ai")
        return cfg
    end }
end

local asked
local recap_text
package.preload["ai"] = function()
    return { priorSummaries = function(identity, current_idx, chapters)
        asked = { identity = identity, current_idx = current_idx, chapters = chapters }
        return recap_text
    end }
end

local last_read = 0
package.preload["book.stats_db"] = function()
    return { summaryByBook = function(source_id, stable_id)
        Assert.eq(source_id, "wechat")
        Assert.eq(stable_id, "b1")
        return { total_seconds = 0, pages = 0, last_read = last_read }
    end }
end

local identity = { source_id = "wechat", stable_id = "b1" }
local session = { identity = identity }
local current_idx = 5
package.preload["reader.session"] = function()
    return {
        current = function() return session end,
        chapterIndex = function() return current_idx end,
    }
end

local Recap = require("features.ai.recap")

-- 最多 3 章，当前章交给 ai.priorSummaries（它只取当前章之前）
recap_text = "第三章\n他出发了。"
Recap.show()
Assert.eq(asked.identity, identity)
Assert.eq(asked.current_idx, 5)
Assert.eq(asked.chapters, 3)
Assert.eq(shown[1].text, "第三章\n他出发了。")
shown = {}
Themed.on_show = function(o) shown[#shown + 1] = o end

---@param days number
---@return integer
local function daysAgo(days)
    return os.time() - math.floor(days * 86400)
end

-- 开书：隔 3 天以上弹卡片
last_read = daysAgo(3)
Recap.onReaderReady()
Assert.len(shown, 1)
Assert.eq(shown[1].kind, "text_viewer")
Assert.eq(shown[1].title, "前情提要")
Assert.is_false(shown[1].fullscreen)
Assert.matches(shown[1].text, "他出发了")

-- 隔不到 3 天、从没读过、开关关：不弹
last_read = daysAgo(2.9)
Recap.onReaderReady()
last_read = 0
Recap.onReaderReady()
last_read = daysAgo(10)
cfg.ai_recap = false
Recap.onReaderReady()
cfg.ai_recap = true
Assert.len(shown, 1)

-- 开书自动弹时没有摘要：安静，不提示
recap_text = nil
Recap.onReaderReady()
Assert.len(shown, 1)

-- 手动打开没有摘要：提示怎么开
Recap.show()
Assert.len(shown, 2)
Assert.eq(shown[2].kind, "toast")
Assert.matches(shown[2].text, "读完章节自动生成摘要")

-- 不在任何章：手动打开也只提示
current_idx = nil
Recap.show()
Assert.eq(shown[3].kind, "toast")
current_idx = 5

-- 面板动作：阅读侧「回顾前文」直接打开
recap_text = "一\n开篇。"
local actions = require("features.ai.panel").actions()
Assert.eq(actions[1].id, "ai_recap")
Assert.eq(actions[1].scope, "reader")
Assert.eq(actions[1].title, "回顾前文")
actions[1].run({ ui = {} })
Assert.eq(shown[#shown].kind, "text_viewer")
Assert.matches(shown[#shown].text, "开篇。")

return true
