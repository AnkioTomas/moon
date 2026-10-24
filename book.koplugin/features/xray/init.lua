--[[--
X-Ray：阅读页人物/地点标注与实体面板。

标注在 marks，面板在 ui，抽取在 fetch。入口在侧栏 Tab、阅读面板与手势。

@module koplugin.book.features.xray.init
--]]

local _ = require("gettext")
local Xray = {}

--- 登记「刷新 X-Ray」手势，事件由下面的 events 接住。
function Xray.onCreate()
    require("dispatcher"):registerAction("book_xray_refresh", {
        category = "none",
        event = "BookXrayRefresh",
        title = _("刷新 X-Ray"),
        reader = true,
    })
    require("dispatcher"):registerAction("book_xray_marks", {
        category = "none",
        event = "BookXrayMarks",
        title = _("开关 X-Ray 标记"),
        reader = true,
    })
end

--- X-Ray 开着且当前不是订阅文章（ephemeral 源不是书，没有可累积的人物 / 地点）。
---@return boolean
function Xray.available()
    if not require("utils.settings").get("features.xray").book_xray_enabled then return false end
    local current = require("reader.session").current()
    return not (current and current.identity.ephemeral)
end

local last_stage

--- 翻页：新进一章先识别本章，读过大半再把下一章也带上；同一阶段只试一次（被拦下时下次翻页再试）。
---@param plugin BookPlugin
local function onPageUpdated(plugin)
    if not Xray.available() or not require("utils.settings").get("features.xray").book_xray_auto then return end
    local Session = require("reader.session")
    local page, count = Session.chapterPages()
    local late = page ~= nil and count ~= nil and page / count >= 0.6
    local stage = tostring(Session.chapterIndex()) .. (late and "n" or "c")
    if stage == last_stage then return end
    if require("features.xray.ui").prefetch(plugin.ui, late) then last_stage = stage end
end
require("utils.extension").add("reader.page_updated", onPageUpdated)

Xray.events = {
    ---@param plugin BookPlugin
    BookXrayRefresh = function(plugin)
        if not plugin.ui.document or not Xray.available() then return false end
        require("features.xray.ui").refresh(plugin.ui)
        return true
    end,
    BookXrayMarks = function(plugin)
        if not plugin.ui.document or not Xray.available() then return false end
        local Marks = require("features.xray.marks")
        Marks.setEnabled(not Marks.enabled(), plugin.ui)
        return true
    end,
    CloseDocument = function(plugin)
        last_stage = nil
        require("features.xray.marks").release(plugin.ui)
    end,
}

---@param plugin BookPlugin
function Xray.onReaderReady(plugin)
    last_stage = nil
    require("features.xray.marks").install(plugin.ui)
end

return Xray
