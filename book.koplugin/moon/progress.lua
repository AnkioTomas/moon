--[[--
阅读进度：从当前文档算比例，推到 / 拉自数据源。

@module koplugin.book.moon.progress
--]]

local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local Cache = require("moon.cache")
local _ = require("gettext")
local T = require("ffi/util").template

local Progress = {}

function Progress.filenameFor(ui)
    if not ui or not ui.document or not ui.document.file then
        return nil
    end
    return Cache.remoteFilename(ui.document.file)
end

function Progress.fraction(ui)
    if not ui or not ui.document then
        return 0
    end
    local doc = ui.document
    if doc.getXPointer and doc.getProportionFromXPointer then
        local ok, p = pcall(function()
            return doc:getProportionFromXPointer(doc:getXPointer())
        end)
        if ok and type(p) == "number" then
            return math.max(0, math.min(1, p))
        end
    end
    if ui.getCurrentPage and doc.getPageCount then
        local page = ui:getCurrentPage() or 1
        local total = doc:getPageCount() or 1
        if total > 0 then
            return math.max(0, math.min(1, page / total))
        end
    end
    return 0
end

function Progress.push(ui, source, show_msg)
    local filename = Progress.filenameFor(ui)
    if not filename or not source then
        return
    end
    local frac = Progress.fraction(ui)
    NetworkMgr:runWhenOnline(function()
        local res, err = source:updateProgress(filename, frac, 0, 0)
        if show_msg then
            UIManager:show(InfoMessage:new{
                text = res and _("进度已上传") or (err or _("上传失败")),
                timeout = 2,
            })
        elseif not res then
            logger.warn("book push progress failed", err)
        end
    end)
end

function Progress.pull(ui, source, show_msg)
    local filename = Progress.filenameFor(ui)
    if not filename or not source then
        return
    end
    NetworkMgr:runWhenOnline(function()
        local res, err = source:getProgress(filename)
        if not res then
            if show_msg then
                UIManager:show(InfoMessage:new{ text = err or _("拉取失败") })
            end
            return
        end
        local pct = res.data
        if type(pct) ~= "number" then
            if show_msg then
                UIManager:show(InfoMessage:new{ text = _("远端无进度"), timeout = 2 })
            end
            return
        end
        if pct > 1 then
            pct = pct / 100
        end
        if ui.document and ui.document.getXPointerFromProportion then
            local xptr = ui.document:getXPointerFromProportion(pct)
            if xptr and ui.rolling then
                ui.rolling:onGotoXPointer(xptr)
            elseif xptr and ui.link then
                ui.link:onGotoXPointer(xptr)
            end
        elseif ui.document and ui.document.getPageCount then
            local total = ui.document:getPageCount() or 1
            local page = math.max(1, math.min(total, math.floor(pct * total + 0.5)))
            ui:handleEvent(Event:new("GotoPage", page))
        end
        if show_msg then
            UIManager:show(InfoMessage:new{
                text = T(_("已跳转到约 %1%"), string.format("%.1f", pct * 100)),
                timeout = 2,
            })
        end
    end)
end

return Progress
