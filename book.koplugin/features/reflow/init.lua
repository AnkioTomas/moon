--[[--
重新排版：取出整本书的纯文字，重新识别章节、合并断行，生成 EPUB 放在这本书的缓存工作目录里。原书不动。

文件（`<书的工作目录>/reflow/`，随清缓存 / 删书一起清掉）：
- `book.epub`：排版版。
- `meta.json`：`{ origin, file }`，排版版与它的原书路径。
- `extract.txt` / `extract.txt.part` + `extract.cursor`：非 TXT 取字断点；取消 / 休眠可续，EPUB 成功后清掉。

文字来源：TXT 直接读文件（保留原始换行，章节识别最准）；流式书优先整棵 DOM 一次倒出再剥成纯文本，
失败或固定版式（PDF/DjVu）再逐页取字（见 extract）。读文件、章节识别、打包都在子进程里；
取字仍在 UI 线程（文档对象出不了主进程）。取字、识别、打包串成一个可转后台的 convert 任务。
章节：原文档自带目录（`ui.toc`）的标题整行命中即切章，没有目录或标题对不上的再按常见章节写法识别。

身份：排版版是同一本书的另一个文件，books.path 不动。开书时按 meta.json 解析回同一身份，
进度、统计都记在这本书上；上次读的版本记在原书 sidecar（`DerivedNote.remember`），桌面开书时恢复。排版版结构和原书不同，xpointer 不通用，切换时按全书比例落位；
划线留在排版版自己的 sidecar，和原书之间按文字互相定位（见 reader/session/derived_note）。
章节源（`type == "chapter"`）的书不做：章节文件各自独立，没有整本可排。

@module koplugin.book.features.reflow
--]]

require("l10n").apply()

local DerivedNote = require("reader.session.derived_note")
local JSON = require("json")
local Text2Epub = require("convert.text2epub")
local readMeta = DerivedNote.readMeta
local T = require("ffi/util").template
local _ = require("gettext")

local Reflow = {}

--- 章节识别 + 写 EPUB 的固定底（秒）。与页数弱相关，长书也不再叠乘。
local EPUB_SECONDS = 90
--- 流式书 DOM 一次倒出的取字底（秒）；长书通常几十秒内，偏长一点报。
local DOM_SECONDS = 45
--- 逐页路径：取字实测校准，至少处理这么多页才信 elapsed/页。
local ETA_WARMUP_PAGES = 20
--- 逐页路径按 Kindle 估（约 35ms/页）。偏长比偏短好。
local MS_PER_PAGE = 35

---@param identity BookIdentity
---@return string
local function workDir(identity)
    return require("utils.paths").bookWorkDir(identity.stable_id, identity.source_id) .. "/reflow"
end

--- 把秒数收成「约 N 分钟」；向上取整，避免报短。
---@param seconds number|nil
---@return string
function Reflow.formatEta(seconds)
    local minutes = math.max(1, math.ceil((tonumber(seconds) or 0) / 60))
    if minutes >= 60 then
        return string.format(_("约 %d 小时 %d 分"), math.floor(minutes / 60), minutes % 60)
    end
    return string.format(_("约 %d 分钟"), minutes)
end

--- 开跑前粗估整次排版秒数。
--- 流式 + DOM：取字固定底 + 转 EPUB；固定版式 / DOM 不可用：剩余页 × 常数 + 转 EPUB。
---@param ui table ReaderUI
---@param identity BookIdentity
---@param wipe boolean|nil 真=丢掉断点整本重来
---@return number
function Reflow.estimateSeconds(ui, identity, wipe)
    local path = ui.document and ui.document.file or ""
    if type(path) == "string" and path:lower():match("%.txt$") then
        return EPUB_SECONDS
    end
    local Extract = require("features.reflow.extract")
    local dir = workDir(identity)
    if not wipe and Extract.donePath(dir) then
        return EPUB_SECONDS
    end
    if Extract.canDumpDom(ui) then
        return DOM_SECONDS + EPUB_SECONDS
    end
    local ok, count = pcall(function() return ui.document:getPageCount() end)
    count = ok and tonumber(count) or 0
    if count < 1 then return EPUB_SECONDS end
    local done = wipe and 0 or Extract.donePages(dir, count)
    return math.max(0, count - done) * MS_PER_PAGE / 1000 + EPUB_SECONDS
end

---@param path string
---@return boolean
local function isFile(path)
    return require("libs/libkoreader-lfs").attributes(path, "mode") == "file"
end

--- 正在读排版版（面板按钮高亮）。
---@param ui table
---@return boolean
function Reflow.active(ui)
    local meta = readMeta(workDir(require("reader.session").current().identity))
    return meta ~= nil and meta.file == ui.document.file
end

--- 整本书、且当前文档能取出文字（流式文档，或有文字层接口的 PDF/DjVu）才能排；
--- 章节源的书、属主源已卸载（第三方源插件）的不做。
--- 读别的衍生版（如双语版）时不做：衍生版的划线只会和它的原书收敛，再套一层就回不到笔记库。
---@param ui table
---@return boolean
function Reflow.available(ui)
    local session = require("reader.session").current()
    local source = session and session.identity.source
    if source == nil or source.type == "chapter" then return false end
    if DerivedNote.originOf(ui.document.file) and not Reflow.active(ui) then return false end
    return ui.rolling ~= nil or ui.document.getPageTextBoxes ~= nil
end

---@param origin string 原书路径
---@param identity BookIdentity
---@param headings string[]
---@return table
local function buildOpts(origin, identity, headings)
    local book = identity.book
    return {
        source = origin,
        title = book.title,
        author = book.authors,
        identifier = "moon-reflow-" .. require("utils.paths").slugFor(origin),
        reflow = true,
        headings = headings,
    }
end

--- 原文档自带目录的标题。
---@param ui table ReaderUI
---@return string[]
local function tocHeadings(ui)
    ui.toc:fillToc()
    local headings = {}
    for _idx, item in ipairs(ui.toc.toc) do
        headings[#headings + 1] = item.title
    end
    return headings
end

--- 取全文、识别章节、打包成 EPUB 写进工作目录并记下 meta，完成后回调排版版路径。原书不动。
--- 目录标题与原书路径开头就取好；TXT 由子进程读原文件，其余格式在 UI 线程上分批取字（批间让出输入），
--- 取字断点落在工作目录（取消 / 休眠可续）；取字中途关书报「文档已关闭」。
--- 打包先写 `book.epub.part` 成功再改名（html2epub）：取消停掉当前一步并删掉半截 .part，
--- 已有的排版版与已取完的正文不受影响。可取消，取消后 cb 不再触发。
---@param ui table ReaderUI，正在读原书
---@param identity BookIdentity
---@param cb fun(path: string|nil, err: string|nil)
---@param on_progress fun(text: string, done: integer, total: integer) 当前步骤与进度
---@return { cancel: fun() }
function Reflow.runAsync(ui, identity, cb, on_progress)
    local Paths = require("utils.paths")
    local Extract = require("features.reflow.extract")
    local origin = ui.document.file
    local opts = buildOpts(origin, identity, tocHeadings(ui))
    local dir = workDir(identity)
    local dest = dir .. "/book.epub"
    opts.dest = dest
    local current, cancelled

    local function finish(ok, err)
        if not ok then return cb(nil, err or _("排版失败")) end
        -- 重新排版写回同一路径，sidecar 按路径跟着新文件：旧划线的 xpointer 指向旧结构，连同基线一起清掉，
        -- 原书的划线、只在排版版里的划线，下次打开排版版时都按文字重新搜进来。
        DerivedNote.purge(dest)
        -- 这里跑在 job 回调里，抛错会被吞掉、cb 永远不来，调用方的进度窗就关不掉：失败一律走 cb。
        local meta_part = dir .. "/meta.json.part"
        local f, err_open = io.open(meta_part, "wb")
        if not f then return cb(nil, err_open) end
        local written, err_write = f:write(JSON.encode({ origin = origin, file = dest }))
        f:close()
        local renamed, err_rename = nil, err_write
        if written then renamed, err_rename = os.rename(meta_part, dir .. "/meta.json") end
        if not renamed then
            os.remove(meta_part)
            return cb(nil, err_rename)
        end
        -- EPUB 已成：正文断点可清，省空间；下次「重新排版」会再取。
        Extract.clearCheckpoint(dir)
        cb(dest)
    end

    ---@param text_file string|nil 提取出的临时 txt；nil 时子进程读原文件（TXT）
    local function build(text_file)
        if cancelled then
            -- 工作目录断点留下；取消后晚到的缓存临时文件丢掉。
            if text_file and text_file:sub(1, #dir + 1) ~= dir .. "/" then
                os.remove(text_file)
            end
            return
        end
        Paths.ensureBookWork(identity.stable_id, identity.source_id)
        local ok, err = Paths.ensureDir(dir)
        if not ok then return cb(nil, err) end
        -- 全文只落盘，不进主进程字符串；子进程自己读。source 仍是原书路径（推断书名）。
        opts.text = nil
        opts.text_file = text_file
        current = Text2Epub.build(opts, function(ok_build, build_err)
            finish(ok_build, build_err)
        end, on_progress)
    end

    if origin:lower():match("%.txt$") then
        build(nil)
    else
        local reportExtract
        if Extract.canDumpDom(ui) then
            -- DOM 一次倒出：进度只有 0/1→1/1，报固定剩余（转 EPUB 为主）。
            reportExtract = function(text, done, total)
                on_progress(
                    T(_("正在提取文字（预计剩余 %1）"), Reflow.formatEta(DOM_SECONDS + EPUB_SECONDS)),
                    done, total)
            end
        else
            -- 逐页：先用设备常数，跑过若干页后改用实测速度。
            local t0 = require("utils.perf").now()
            local ok_count, page_count = pcall(function() return ui.document:getPageCount() end)
            page_count = ok_count and tonumber(page_count) or 0
            local start_done = Extract.donePages(dir, page_count)
            reportExtract = function(_text, done, total)
                local left = math.max(0, (tonumber(total) or 0) - (tonumber(done) or 0))
                local processed = math.max(0, (tonumber(done) or 0) - start_done)
                local extract_eta
                if processed >= ETA_WARMUP_PAGES then
                    local elapsed = (require("utils.perf").now() - t0) / 1000
                    if elapsed > 0 then
                        extract_eta = left * (elapsed / processed)
                    end
                end
                if not extract_eta then
                    extract_eta = left * MS_PER_PAGE / 1000
                end
                on_progress(
                    T(_("正在提取文字（预计剩余 %1）"), Reflow.formatEta(extract_eta + EPUB_SECONDS)),
                    done, total)
            end
        end
        current = Extract.run(ui, function(text_file, err)
            if not text_file then return cb(nil, err) end
            build(text_file)
        end, reportExtract, { dir = dir })
    end
    return { cancel = function()
        cancelled = true
        if current then current.cancel() end
        os.remove(dest .. ".part")
        -- 不删 kept_text / 工作目录断点：下次接着取或跳过取字。
        opts.text_file = nil
    end }
end

local ANCHOR_KEY = "moon_reflow_anchor"
local ANCHOR_CHARS = 16

--- 当前页开头的一小段文字，两版排版都是 CREngine 时用它在对侧搜出准确落点（比例会因图片、封面页、断行合并而偏）。
---@param ui table ReaderUI
---@return string|nil
local function anchorText(ui)
    local document = ui.document
    local page = ui.rolling and ui.rolling.current_page
    if not page or page >= document:getPageCount() then return nil end
    local text = document:getTextFromXPointers(document:getPageXPointer(page), document:getPageXPointer(page + 1))
    local Text = require("utils.text")
    local line = Text.trim(text or ""):match("^[^\n]+")
    if not line then return nil end
    local chars = {}
    for char in line:gmatch(Text.UTF8_CHAR) do
        chars[#chars + 1] = char
        if #chars == ANCHOR_CHARS then break end
    end
    return table.concat(chars)
end

--- 目标文档就绪后按锚点文字落位；搜不到就保留按比例的落点。
---@param plugin BookPlugin
function Reflow.onReaderReady(plugin)
    local ui = plugin.ui
    local anchor = ui.doc_settings:readSetting(ANCHOR_KEY)
    if not anchor then return end
    ui.doc_settings:delSetting(ANCHOR_KEY)
    if not ui.rolling then return end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("reflow anchor", function()
        local xp = DerivedNote.locate(ui.document, anchor.text, anchor.fraction)
        if xp then ui:handleEvent(require("ui/event"):new("GotoXPointer", xp)) end
    end))
end

--- 把排版、落位写进目标文件的 sidecar 再换文档。两版 xpointer 不通用：清掉目标的 last_xpointer，
--- 按全书比例落位（流式文档读 last_percent，固定版式读 last_page）；两边都是 CREngine 时再记一段
--- 当前页开头的文字，打开后按文字精确落位。
---@param ui table ReaderUI
---@param identity BookIdentity
---@param target string
---@param fraction number 当前全书进度 0..1
local function switchTo(ui, identity, target, fraction)
    local Toast = require("ui.themes.widgets.toast")
    if not isFile(target) then
        Toast:new{ text = _("文件不存在") }:show()
        return
    end
    local settings = require("docsettings"):open(target)
    -- 只有两边都是 CREngine 才搬排版：copt_ 键在 PDF 的 sidecar 里是 KOPT 的另一套含义。
    local prefs = require("reader.prefs").capture(ui)
    local provider = require("document/documentregistry"):getProvider(target)
    if prefs and provider and provider.provider == "crengine" then
        require("reader.prefs").write(settings, prefs)
        local text = anchorText(ui)
        settings:saveSetting(ANCHOR_KEY, text and { text = text, fraction = fraction } or nil)
    end
    settings:delSetting("last_xpointer")
    settings:saveSetting("last_percent", fraction)
    local pages = settings:readSetting("doc_pages")
    if pages then
        settings:saveSetting("last_page", math.max(1, math.floor(fraction * pages + 0.5)))
    end
    settings:flush()
    local origin = DerivedNote.originOf(ui.document.file) or ui.document.file
    DerivedNote.remember(ui, origin, target ~= origin and target or nil)
    ui:switchDocument(target)
end

---@param identity BookIdentity
---@return string
local function taskKey(identity)
    return "reflow\0" .. identity.source_id .. "\0" .. identity.stable_id
end

--- 取字、识别章节、生成排版版整个是一个后台任务（可取消、可转后台）→ 完成后询问切过去。
--- 完成时若还在读原书就询问打开，否则只提示。
---@param ui table ReaderUI，正在读原书
---@param identity BookIdentity
---@param wipe boolean|nil 真则清掉取字断点，整本重来
local function start(ui, identity, wipe)
    local Toast = require("ui.themes.widgets.toast")
    local origin = ui.document.file
    local dir = workDir(identity)

    local function run()
        if wipe then require("features.reflow.extract").clearCheckpoint(dir) end
        require("workers.ui.task_dialog").start{
            key = taskKey(identity),
            kind = "convert",
            title = T(_("%1（排版）"), identity.book and identity.book.title or ""),
            restartable = true,
            run = function(report, done)
                return Reflow.runAsync(ui, identity, function(path, err)
                    -- 取字有进展（断点 / 已完成正文）时失败不算白跑，队列可立刻续。
                    local progressed = require("features.reflow.extract").hasCheckpoint(dir)
                        or require("features.reflow.extract").donePath(dir) ~= nil
                    done({ ok = path ~= nil, file = path, err = err, progressed = progressed })
                end, report)
            end,
            on_done = function(result)
                if not result.ok then
                    Toast:new{ text = result.err and tostring(result.err):match("[^\n]*") or _("排版失败") }:show()
                    return
                end
                local reader = require("apps/reader/readerui").instance
                if not (reader and reader.document and reader.document.file == origin) then
                    Toast:new{ text = _("排版版已生成") }:show()
                    return
                end
                require("ui.themes.widgets.confirm"):new{
                    text = _("排版版已生成，现在打开？"),
                    ok_text = _("打开"),
                    ok_callback = function()
                        switchTo(reader, identity, result.file, require("reader.session").current().fraction)
                    end,
                }:show()
            end,
        }
    end

    if origin:lower():match("%.txt$") then
        run()
        return
    end
    local Extract = require("features.reflow.extract")
    -- DOM 路径不认旧页断点；只有成品 txt 或（非 DOM 的）页断点才算续跑。
    local resume = not wipe and (
        Extract.donePath(dir) ~= nil
        or (not Extract.canDumpDom(ui) and Extract.hasCheckpoint(dir))
    )
    local eta = Reflow.formatEta(Reflow.estimateSeconds(ui, identity, wipe))
    local body = resume
        and _("检测到上次未完成的排版，将从断点继续。图片、脚注和原排版仍会丢失；排版版另存，原书保留不变。")
        or _("只保留文字并重新识别章节，图片、脚注和原排版会丢失；排版版另存，原书保留不变。继续？")
    require("ui.themes.widgets.confirm"):new{
        text = body .. "\n\n" .. T(_("预计需要 %1（可转后台，中断可续）。"), eta),
        ok_text = resume and _("继续排版") or _("继续"),
        ok_callback = run,
    }:show()
end

--- 快捷面板入口：读排版版时切回原书；这本书正在生成排版版时跟随进度；读原书时打开已有排版版或重新排版。
---@param ui table
function Reflow.show(ui)
    local identity = require("reader.session").current().identity
    local fraction = require("reader.session").current().fraction
    local dir = workDir(identity)
    local meta = readMeta(dir)
    if meta and ui.document.file == meta.file then
        switchTo(ui, identity, meta.origin, fraction)
        return
    end
    local running = require("workers.tasks").get(taskKey(identity))
    if running then
        require("workers.ui.task_dialog").follow(running)
        return
    end
    local Extract = require("features.reflow.extract")
    local has_epub = meta and meta.origin == ui.document.file and isFile(meta.file)
    if not has_epub then
        start(ui, identity, false)
        return
    end
    require("ui.themes.widgets.sheet"):new{ title = _("优化排版"), items = {
        { text = _("打开排版版"), callback = function() switchTo(ui, identity, meta.file, fraction) end },
        { text = _("重新排版"), callback = function() start(ui, identity, true) end },
    } }:show()
end

return Reflow
