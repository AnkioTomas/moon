--[[--
前情提要：把当前章之前最近几章的 AI 摘要拼成一张卡片。纯本地，离线可用，不调 AI。

开书时（隔 GAP_DAYS 天以上没读这本书）自动弹一次；快捷面板「回顾前文」随时手动打开。
摘要怎么取（只取当前章之前）见 `ai.priorSummaries`。

@module koplugin.book.features.ai.recap
--]]

require("l10n").apply()

local _ = require("gettext")

local Recap = {}

--- 隔这么多天再开书才自动弹。
local GAP_DAYS = 3
--- 最多拼几章。
local CHAPTERS = 3

--- 弹前情提要卡片；没有摘要时提示一下（手动打开时用）。
---@param quiet boolean|nil 为真时没有摘要就什么都不弹（开书自动弹用）
function Recap.show(quiet)
    local Session = require("reader.session")
    local session = Session.current()
    local idx = session and Session.chapterIndex(session)
    local text = idx and require("ai").priorSummaries(session.identity, idx, CHAPTERS)
    if not text then
        if not quiet then
            require("ui.themes.widgets.toast"):new{
                text = _("还没有前文摘要：打开「读完章节自动生成摘要」后顺着读，读完的章会生成摘要"),
                timeout = 3,
            }:show()
        end
        return
    end
    require("ui.themes.widgets.text_viewer"):new{
        title = _("前情提要"), text = text, fullscreen = false,
    }:show()
end

--- 开书：开关开着、上次阅读在 GAP_DAYS 天以前，等首绘之后弹。
--- 按章打开时每次切章也会到这里，但刚读过的书距今不到一天，不会弹。
function Recap.onReaderReady()
    if require("utils.settings").get("ai").ai_recap ~= true then return end
    local session = require("reader.session").current()
    if not session then return end
    local identity = session.identity
    local last_read = require("book.stats_db").summaryByBook(identity.source_id, identity.stable_id).last_read
    if last_read <= 0 or os.time() - last_read < GAP_DAYS * 86400 then return end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("ai recap", function()
        if require("reader.session").current() ~= session then return end
        Recap.show(true)
    end))
end

return Recap
