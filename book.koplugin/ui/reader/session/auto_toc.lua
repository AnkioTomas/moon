--[[--
整书模式自动目录：文档自带目录不足两项时，全文扫描章节标题，写入 KOReader 自定义目录。

扫描在 fork 子进程里跑（大 TXT 的 findAllText 要数秒）；结果交给 ReaderHandMade，
由它负责落 sidecar、重排后按 xpointer 重算页码、以及用户编辑/清除。
每本书只自动扫描一次（doc_settings.moon_auto_toc），用户清掉自定义目录后不会被再次覆盖。

@module koplugin.book.ui.reader.session.auto_toc
--]]

require("l10n").apply()

local Job = require("workers.job")
local Text2Epub = require("convert.text2epub")
local DocumentToc = require("ui.reader.session.document_toc")
local logger = require("utils.log")
local T = require("ffi/util").template
local _ = require("gettext")

local AutoToc = {}

local SCANNED_KEY = "moon_auto_toc"
-- ECMAScript 正则（crengine/SRELL），只做粗筛；是否为标题由 Text2Epub.chapterTitle 按整行判定。
local PATTERN = "第\\s*[0-9零〇一二三四五六七八九十百千万两]+\\s*[章回节集幕卷部篇]"
    .. "|chapter\\s|section\\s|序章|序言|前言|楔子|引子|尾声|后记|番外|终章|完本感言"
local MAX_HITS = 5000
-- 正文段落也可能以“第三章”开头；标题行不会太长。
local MAX_TITLE_BYTES = 120
local MATCH_ACROSS_TEXT_NODES = 0x0001

--- 扫描文档中的章节标题行，按文档顺序返回。
---@param document table CreDocument
---@return { title: string, xpointer: string }[]
function AutoToc.scan(document)
    local hits = document:findAllText(PATTERN, true, 0, MAX_HITS, true, MATCH_ACROSS_TEXT_NODES) or {}
    local entries, seen = {}, {}
    for _, hit in ipairs(hits) do
        local node = (hit.start:gsub("%.%d+$", ""))
        if not seen[node] then
            seen[node] = true
            local line = document:getTextFromXPointer(hit.start)
            local title = line and #line <= MAX_TITLE_BYTES and Text2Epub.chapterTitle(line)
            if title then
                entries[#entries + 1] = { title = title, xpointer = node .. ".0" }
            end
        end
    end
    return entries
end

---@param ui table ReaderUI
---@param entries { title: string, xpointer: string }[]
local function install(ui, entries)
    for _, entry in ipairs(entries) do
        entry.page = ui.document:getPageFromXPointer(entry.xpointer)
        entry.depth = 1
    end
    local handmade = ui.handmade
    handmade.toc = entries
    handmade.toc_enabled = true
    handmade:setupToc()
    ui.view.footer:maybeUpdateFooter()
end

--- 整书 ReaderReady 后调用：条件满足则后台扫描，完成后替换目录。
---@param session ReaderSessionSnapshot
function AutoToc.start(session)
    local ui = session.ui
    local handmade = ui.handmade
    if not ui.rolling or not handmade or handmade:isHandmadeTocEnabled()
        or ui.doc_settings:isTrue(SCANNED_KEY) then
        return
    end
    local toc = DocumentToc.list(ui)
    if toc and #toc >= 2 then return end

    local document = ui.document
    session.auto_toc_job = Job.run(function()
        return AutoToc.scan(document)
    end, {
        name = "auto_toc",
        kind = "medium",
        timeout = 120,
        on_done = function(entries)
            session.auto_toc_job = nil
            ui.doc_settings:saveSetting(SCANNED_KEY, true)
            if #entries < 2 then return end
            install(ui, entries)
            local UIManager = require("ui/uimanager")
            UIManager:show(require("ui/widget/infomessage"):new{
                text = T(_("已自动生成目录（%1 章）"), #entries),
                timeout = 2,
            })
        end,
        on_failed = function(err)
            session.auto_toc_job = nil
            logger.warn("auto toc scan failed", err)
        end,
    })
end

--- 关书时取消在飞扫描。
---@param session ReaderSessionSnapshot|nil
function AutoToc.stop(session)
    local job = session and session.auto_toc_job
    if job then
        session.auto_toc_job = nil
        job:cancel()
    end
end

return AutoToc
