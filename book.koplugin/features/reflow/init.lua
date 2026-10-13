--[[--
重新排版：取出整本书的纯文字，重新识别章节、合并断行，生成 EPUB 放在这本书的缓存工作目录里。原书不动。

文件（`<书的工作目录>/reflow/`，随清缓存 / 删书一起清掉）：
- `book.epub`：排版版。
- `meta.json`：`{ origin, file }`，排版版与它的原书路径。

文字来源：TXT 直接读文件（保留原始换行，章节识别最准）；其余格式从打开的文档逐页取字（见 extract），
流式文档与带文字层的 PDF/DjVu 都行。分析得到的全文由预览持有，确认后原样交给转换，不重复提取。
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

---@class ReflowPreview
---@field text string 全文
---@field headings string[] 原文档目录的标题
---@field titles string[] 识别出的目录标题

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

---@param parsed { chapters: { title: string, toc: boolean|nil }[] }
---@return string[]
local function tocTitles(parsed)
    local titles = {}
    for _idx, chapter in ipairs(parsed.chapters) do
        if chapter.toc ~= false then
            titles[#titles + 1] = chapter.title ~= "" and chapter.title
                or ("#" .. (#titles + 1))
        end
    end
    return titles
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

--- 读出全文并识别章节，供预览目录使用。
---@param ui table ReaderUI，正在读原书
---@param identity BookIdentity
---@param cb fun(preview: ReflowPreview|nil, err: string|nil)
---@return { cancel: fun() }
function Reflow.analyzeAsync(ui, identity, cb)
    local origin = ui.document.file
    local headings = tocHeadings(ui)
    local function done(text, err)
        if not text then
            cb(nil, err)
            return
        end
        local parsed = Text2Epub.parse(text, buildOpts(origin, identity, headings))
        cb({ text = text, headings = headings, titles = tocTitles(parsed) })
    end
    if origin:lower():match("%.txt$") then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("reflow read", function()
            done(Text2Epub.read(origin))
        end))
        return { cancel = function() end }
    end
    return require("features.reflow.extract").run(ui, done)
end

--- 把预览得到的全文转成 EPUB 写进工作目录并记下 meta，完成后回调排版版路径。原书不动。
---@param identity BookIdentity
---@param origin string 原书路径
---@param preview ReflowPreview `analyzeAsync` 的结果
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Reflow.applyAsync(identity, origin, preview, cb)
    local Paths = require("utils.paths")
    local dir = workDir(identity)
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    assert(Paths.ensureDir(dir))
    local opts = buildOpts(origin, identity, preview.headings)
    opts.dest = dir .. "/book.epub"
    opts.text = preview.text
    return Text2Epub.build(opts, function(ok, err)
        if not ok then
            cb(nil, err or _("排版失败"))
            return
        end
        -- 重新排版写回同一路径，sidecar 按路径跟着新文件：旧划线的 xpointer 指向旧结构，连同基线一起清掉，
        -- 原书的划线、只在排版版里的划线，下次打开排版版时都按文字重新搜进来。
        DerivedNote.purge(opts.dest)
        local f = assert(io.open(dir .. "/meta.json.part", "wb"))
        assert(f:write(JSON.encode({ origin = origin, file = opts.dest })))
        assert(f:close())
        assert(os.rename(dir .. "/meta.json.part", dir .. "/meta.json"))
        cb(opts.dest)
    end)
end

--- 把排版、落位写进目标文件的 sidecar 再换文档。两版 xpointer 不通用：清掉目标的 last_xpointer，
--- 按全书比例落位（流式文档读 last_percent，固定版式读 last_page）。
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

--- 分析 → 预览目录 → 生成排版版 → 切过去。
---@param ui table ReaderUI，正在读原书
---@param identity BookIdentity
local function start(ui, identity)
    local List = require("ui.themes.widgets.list")
    local Toast = require("ui.themes.widgets.toast")
    local origin = ui.document.file

    ---@param preview ReflowPreview
    local function apply(preview)
        local loading = Toast:new{ text = _("正在优化排版…") }
        loading:show()
        Reflow.applyAsync(identity, origin, preview, function(path, err)
            loading:close()
            if not path then
                Toast:new{ text = err or _("排版失败") }:show()
                return
            end
            switchTo(ui, identity, path, require("reader.session").current().fraction)
        end)
    end

    --- 首行确认优化，其余章节只读；右上角关闭即放弃。未识别到章节只提示不弹表。
    ---@param preview ReflowPreview
    local function showPreview(preview)
        if #preview.titles == 0 then
            Toast:new{ text = _("未识别到章节") }:show()
            return
        end
        local list
        local items = { { text = _("确认优化"), icon = "check", keep_open = true, callback = function()
            list:close()
            apply(preview)
        end } }
        for _idx, title in ipairs(preview.titles) do
            items[#items + 1] = { text = title, enabled = false }
        end
        list = List:new{
            title = _("排版预览"),
            subtitle = T(_("识别到 %1 章；排版版另存，原书保留不变"), #preview.titles),
            items = items,
        }
        list:show()
    end

    local function runAnalyze()
        local handle
        local loading = Toast:new{
            text = _("正在分析章节…"),
            -- 结果回来时先清 handle 再关窗，所以只有用户点掉才会取消提取。
            close_callback = function()
                if handle then handle.cancel() end
            end,
        }
        loading:show()
        handle = Reflow.analyzeAsync(ui, identity, function(preview, err)
            handle = nil
            loading:close()
            if not preview then
                Toast:new{ text = err or _("排版失败") }:show()
                return
            end
            showPreview(preview)
        end)
    end

    if origin:lower():match("%.txt$") then
        runAnalyze()
        return
    end
    require("ui.themes.widgets.confirm"):new{
        text = _("只保留文字并重新识别章节，图片、脚注和原排版会丢失；排版版另存，原书保留不变。继续？"),
        ok_text = _("继续"),
        ok_callback = runAnalyze,
    }:show()
end

--- 快捷面板入口：读排版版时切回原书；读原书时打开已有排版版或重新排版。
---@param ui table
function Reflow.show(ui)
    local identity = require("reader.session").current().identity
    local fraction = require("reader.session").current().fraction
    local meta = readMeta(workDir(identity))
    if meta and ui.document.file == meta.file then
        switchTo(ui, identity, meta.origin, fraction)
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

Reflow._tocTitles = tocTitles

return Reflow
