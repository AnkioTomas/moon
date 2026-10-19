--[[--
重新排版：取出整本书的纯文字，重新识别章节、合并断行，生成 EPUB 放在这本书的缓存工作目录里。原书不动。

文件（`<书的工作目录>/reflow/`，随清缓存 / 删书一起清掉）：
- `book.epub`：排版版。
- `meta.json`：`{ origin, file }`，排版版与它的原书路径。

文字来源：TXT 直接读文件（保留原始换行，章节识别最准）；其余格式从打开的文档逐页取字（见 extract），
流式文档与带文字层的 PDF/DjVu 都行。读文件、章节识别、打包都在子进程里（整本书在 UI 线程上要跑几十秒），
取字、识别、打包串成一个后台任务，不再预览目录确认。
章节：原文档自带目录（`ui.toc`）的标题整行命中即切章，没有目录或标题对不上的再按常见章节写法识别。

身份：排版版是同一本书的另一个文件。切换前 `Store.touch` 把 books.path 指过去，开书时按路径解析回
同一身份，进度、统计都记在这本书上。排版版结构和原书不同，xpointer 不通用，切换时按全书比例落位；
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

---@param identity BookIdentity
---@return string
local function workDir(identity)
    return require("utils.paths").bookWorkDir(identity.stable_id, identity.source_id) .. "/reflow"
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
--- 取字中途关书报「文档已关闭」。打包先写 `book.epub.part` 成功再改名（html2epub）：
--- 取消停掉当前一步并删掉半截 .part，已有的排版版不受影响。可取消，取消后 cb 不再触发。
---@param ui table ReaderUI，正在读原书
---@param identity BookIdentity
---@param cb fun(path: string|nil, err: string|nil)
---@param on_progress fun(text: string, done: integer, total: integer) 当前步骤与进度
---@return { cancel: fun() }
function Reflow.runAsync(ui, identity, cb, on_progress)
    local Paths = require("utils.paths")
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
        cb(dest)
    end

    ---@param text string|nil nil 时子进程读原文件
    local function build(text)
        if cancelled then return end
        Paths.ensureBookWork(identity.stable_id, identity.source_id)
        local ok, err = Paths.ensureDir(dir)
        if not ok then return cb(nil, err) end
        opts.text = text
        current = Text2Epub.build(opts, finish, on_progress)
    end

    if origin:lower():match("%.txt$") then
        build(nil)
    else
        current = require("features.reflow.extract").run(ui, function(text, err)
            if not text then return cb(nil, err) end
            build(text)
        end, on_progress)
    end
    return { cancel = function()
        cancelled = true
        current.cancel()
        os.remove(dest .. ".part")
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
    local line = require("utils.text").trim(text or ""):match("^[^\n]+")
    if not line then return nil end
    local chars = {}
    for char in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
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
    local ok, err = require("book.store").touch(target, identity)
    if not ok then
        Toast:new{ text = err }:show()
        return
    end
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
local function start(ui, identity)
    local Toast = require("ui.themes.widgets.toast")
    local origin = ui.document.file

    local function run()
        require("workers.ui.task_dialog").start{
            key = taskKey(identity),
            kind = "convert",
            title = T(_("%1（排版）"), identity.book and identity.book.title or ""),
            restartable = true,
            run = function(report, done)
                return Reflow.runAsync(ui, identity, function(path, err)
                    done({ ok = path ~= nil, file = path, err = err })
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
    require("ui.themes.widgets.confirm"):new{
        text = _("只保留文字并重新识别章节，图片、脚注和原排版会丢失；排版版另存，原书保留不变。继续？"),
        ok_text = _("继续"),
        ok_callback = run,
    }:show()
end

--- 快捷面板入口：读排版版时切回原书；这本书正在生成排版版时跟随进度；读原书时打开已有排版版或重新排版。
---@param ui table
function Reflow.show(ui)
    local identity = require("reader.session").current().identity
    local fraction = require("reader.session").current().fraction
    local meta = readMeta(workDir(identity))
    if meta and ui.document.file == meta.file then
        switchTo(ui, identity, meta.origin, fraction)
        return
    end
    local running = require("workers.tasks").get(taskKey(identity))
    if running then
        require("workers.ui.task_dialog").follow(running)
        return
    end
    if not (meta and meta.origin == ui.document.file and isFile(meta.file)) then
        start(ui, identity)
        return
    end
    require("ui.themes.widgets.sheet"):new{ title = _("优化排版"), items = {
        { text = _("打开排版版"), callback = function() switchTo(ui, identity, meta.file, fraction) end },
        { text = _("重新排版"), callback = function() start(ui, identity) end },
    } }:show()
end

return Reflow
