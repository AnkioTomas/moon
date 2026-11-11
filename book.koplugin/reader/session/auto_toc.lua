--[[--
整书模式自动目录：文档自带目录不足两项时补一份目录。

先用 crengine 按 h1–h6 生成备用目录（与 KOReader 菜单「备用目录」同一状态，用户可切回）；
不足两项再全文扫描章节标题，写入 KOReader 自定义目录。
扫描在 fork 子进程里跑（大 TXT 的 findAllText 要数秒）；结果交给 ReaderHandMade，
由它负责落 sidecar、重排后按 xpointer 重算页码、以及用户编辑/清除。
每本书只自动扫描一次（doc_settings.moon_auto_toc），用户清掉自定义目录后不会被再次覆盖。
阅读快捷面板的「自动补目录」可忽略已扫描标记再跑一次，已有自定义目录也会被覆盖。

@module koplugin.book.reader.session.auto_toc
--]]

require("l10n").apply()

local Event = require("ui/event")
local Job = require("workers.job")
local Text2Epub = require("convert.text2epub")
local Hierarchy = require("convert.chapter_hierarchy")
local DocumentToc = require("reader.session.document_toc")
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
    for _idx, hit in ipairs(hits) do
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

---@param text string
---@param timeout number|nil
local function toast(text, timeout)
    require("ui.themes.widgets.toast"):new{
        text = text,
        timeout = timeout or 2,
    }:show()
end

---@param entries { title: string, xpointer: string, page: number|nil, depth: integer|nil, toc: boolean|nil }[]
---@return { title: string, xpointer: string, page: number|nil, depth: integer|nil }[]
local function visibleEntries(entries)
    local visible = {}
    for _idx, entry in ipairs(Hierarchy.organize(entries)) do
        if entry.toc ~= false then visible[#visible + 1] = entry end
    end
    return visible
end

---@param ui table
---@param entries { title: string, xpointer: string, page: number|nil, depth: integer|nil }[]
local function install(ui, entries)
    for _idx, entry in ipairs(entries) do
        entry.page = ui.document:getPageFromXPointer(entry.xpointer)
    end
    local handmade = ui.handmade
    handmade.toc = entries
    handmade.toc_enabled = true
    handmade:setupToc()
    ui.view.footer:maybeUpdateFooter()
end

--- 条件满足时启用备用目录。handmade 开启时 getToc 被接管，调用方不要在那时判断。
---@param ui table
---@return boolean
local function tryAlternative(ui)
    local document = ui.document
    if document:isTocAlternativeToc() then return false end
    ui.toc:resetToc()
    document:buildAlternativeToc()
    ui.toc:fillToc()
    if #ui.toc.toc < 2 then return false end
    ui.doc_settings:makeTrue("alternative_toc")
    ui.doc_settings:saveSetting(SCANNED_KEY, true)
    ui:handleEvent(Event:new("UpdateToc"))
    ui.view.footer:maybeUpdateFooter()
    return true
end

---@param session ReaderSessionSnapshot
---@param opts { notify: boolean }
local function startScan(session, opts)
    local ui = session.ui
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
            local visible = visibleEntries(entries)
            if #visible < 2 then
                if opts.notify then
                    toast(_("未找到足够的章节标题，无法生成目录"), 3)
                end
                return
            end
            install(ui, visible)
            toast(T(_("已自动生成目录（%1 章）"), #visible), 2)
        end,
        on_failed = function(err)
            session.auto_toc_job = nil
            logger.warn("auto toc scan failed", err)
            if opts.notify then
                toast(err or _("自动补目录失败"), 3)
            end
        end,
    })
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

    if tryAlternative(ui) then return end

    startScan(session, { notify = false })
end

--- 快捷面板手动重跑：忽略已扫描标记；已有自定义目录也会被覆盖。
---@param session ReaderSessionSnapshot|nil
---@return boolean started
function AutoToc.rerun(session)
    local ui = session and session.ui
    if not ui or not ui.rolling or not ui.handmade then return false end
    if session.identity and session.identity.chapter_idx ~= nil then return false end
    if session.auto_toc_job then
        toast(T(_("「%1」正在执行，请稍后再试"), _("自动补目录")), 3)
        return false
    end
    -- 已有自定义目录时不试备用目录：getToc 被接管，也不能把已扫描出的多章目录换成碎片备用目录。
    if not ui.handmade:isHandmadeTocEnabled() and tryAlternative(ui) then
        toast(T(_("已自动生成目录（%1 章）"), #ui.toc.toc), 2)
        return true
    end
    startScan(session, { notify = true })
    return true
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
