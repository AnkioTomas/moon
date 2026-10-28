--[[--
整书简繁转换：把正文里的汉字转成简体或繁体，生成的转换版放在这本书的缓存工作目录里，原书不动。

文件（`<书的工作目录>/hanzi-<s2t|t2s>/`，随清缓存 / 删书一起清掉）：
- `book.epub|fb2|html`：转换版。
- `meta.json`：`{ origin, file }`，转换版与它的原书路径。
- `source.fb2|html`：非 EPUB 由 CREngine 导出的 DOM，生成成功后删除。

只转标签之间的文字，元素结构不变，原文 xpointer 两版通用（与双语对照同一套做法）。EPUB 逐个改写
XHTML / NCX / OPF，样式与图片原样保留；其余 CREngine 格式导出 DOM，写成 .fb2 / .html，图片不保留。
转换表是 features.ime 自带的 OpenCC 精简表。整个转换在一个子进程里完成，不联网。

身份：转换版是同一本书的另一个文件，切换方式同双语版（`Bilingual.switchTo`）。划线按文字在两版间对应，
简繁字形不同的划线只留在转换版里。章节源（`type == "chapter"`）的书不做。

@module koplugin.book.features.ime.convert
--]]

require("l10n").apply()

local Bilingual = require("features.translate.bilingual")
local DerivedNote = require("reader.session.derived_note")
local JSON = require("json")
local T = require("ffi/util").template
local _ = require("gettext")

local Convert = {}

--- 目标字形 → 工作子目录与任务标题。
local TARGETS = {
    traditional = { dir = "hanzi-s2t", title = _("转为繁体") },
    simplified = { dir = "hanzi-t2s", title = _("转为简体") },
}

---@param identity BookIdentity
---@param target "simplified"|"traditional"
---@return string
local function workDir(identity, target)
    return require("utils.paths").bookWorkDir(identity.stable_id, identity.source_id) .. "/" .. TARGETS[target].dir
end

---@param path string
---@return string|nil
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- 写临时文件再改名，读的一方不会看到半截文件。
---@param path string
---@param data string
local function writeFile(path, data)
    local f = assert(io.open(path .. ".part", "wb"))
    assert(f:write(data))
    assert(f:close())
    assert(os.rename(path .. ".part", path))
end

---@param path string
---@return boolean
local function isMarkup(path)
    local ext = path:lower():match("%.(%w+)$")
    return ext == "xhtml" or ext == "html" or ext == "htm" or ext == "ncx" or ext == "opf"
end

--- 标签之间含汉字等非 ASCII 的文字段转成目标字形。
---@param markup string
---@param target "simplified"|"traditional"
---@return string
function Convert.markup(markup, target)
    local texts = {}
    for text in markup:gmatch(">([^<]+)<") do
        if text:find("[\128-\255]") then texts[#texts + 1] = text end
    end
    if #texts == 0 then return markup end
    local converted = require("features.ime.script").convertTexts(texts, target)
    local idx = 0
    return (markup:gsub(">([^<]+)<", function(text)
        if not text:find("[\128-\255]") then return nil end
        idx = idx + 1
        return ">" .. converted[idx] .. "<"
    end))
end

---@class HanziInput
---@field kind "epub"|"dom"
---@field origin string 原书路径
---@field source string|nil dom：导出的 DOM 文件
---@field dest string 转换版
---@field dir string
---@field target "simplified"|"traditional"

--- EPUB 逐项复制，标记文件转字形；mimetype 必须是第一项且不压缩。
---@param input HanziInput
local function buildEpub(input)
    local tmp = input.dest .. ".part"
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    assert(reader:open(input.origin), reader.err)
    local writer = Archiver.Writer:new()
    os.remove(tmp)
    assert(writer:open(tmp, "epub"), writer.err)
    local mtime = os.time()
    writer:setZipCompression("store")
    assert(writer:addFileFromMemory("mimetype", "application/epub+zip", mtime), writer.err)
    writer:setZipCompression("deflate")
    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local data = assert(reader:extractToMemory(entry.path), reader.err)
            if isMarkup(entry.path) then data = Convert.markup(data, input.target) end
            assert(writer:addFileFromMemory(entry.path, data, mtime), writer.err)
        end
    end
    reader:close()
    writer:close()
    os.remove(input.dest)
    assert(os.rename(tmp, input.dest))
end

--- 子进程：产出转换版；衍生版约定的 meta.json 也在这里写：写盘失败就是任务失败（on_failed），不留给主进程回调。
---@param input HanziInput
---@return boolean
local function build(input)
    if input.kind == "dom" then
        writeFile(input.dest, Convert.markup(assert(readFile(input.source)), input.target))
    else
        buildEpub(input)
    end
    writeFile(input.dir .. "/meta.json", JSON.encode({ origin = input.origin, file = input.dest }))
    return true
end

--- 准备任务输入；非 EPUB 此刻从打开的文档导出 DOM（只有这时手里有文档）。
---@param ui table
---@param identity BookIdentity
---@param target "simplified"|"traditional"
---@return HanziInput
local function prepare(ui, identity, target)
    local dir = workDir(identity, target)
    local Paths = require("utils.paths")
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    assert(Paths.ensureDir(dir))
    local origin = ui.document.file
    local input = { kind = "epub", origin = origin, dest = dir .. "/book.epub", dir = dir, target = target }
    if origin:lower():match("%.epub$") then return input end
    local html = ui.document:getHTMLFromXPointer(".0", 0x0020)
        :gsub("^%s*<RootNode[^>]*>", ""):gsub("</RootNode>%s*$", "")
    local ext = html:find("^%s*<FictionBook") and "fb2" or "html"
    input.kind = "dom"
    input.source = dir .. "/source." .. ext
    input.dest = dir .. "/book." .. ext
    writeFile(input.source, '<?xml version="1.0" encoding="UTF-8"?>\n' .. html)
    return input
end

---@param identity BookIdentity
---@param target "simplified"|"traditional"
---@return string
local function taskKey(identity, target)
    return "hanzi\0" .. TARGETS[target].dir .. "\0" .. identity.source_id .. "\0" .. identity.stable_id
end

--- 后台任务体：子进程转换 → 写 meta。run 返回 { cancel }，取消时杀子进程、删半截文件。
---@param input HanziInput
---@return fun(report: fun(text: string), done: fun(result: table)): { cancel: fun() }
local function task(input)
    return function(report, done)
        report(_("正在转换…"))
        local job = require("workers.job").run(function() return build(input) end, {
            name = "hanzi.build",
            kind = "heavy",
            on_done = function()
                if input.source then os.remove(input.source) end
                done({ ok = true, file = input.dest })
            end,
            on_failed = function(err) done({ ok = false, err = err }) end,
        })
        return { cancel = function()
            job:cancel()
            os.remove(input.dest .. ".part")
        end }
    end
end

--- 正在读这个方向的转换版（面板按钮高亮）。
---@param ui table
---@param target "simplified"|"traditional"
---@return boolean
function Convert.active(ui, target)
    local meta = DerivedNote.readMeta(workDir(require("reader.session").current().identity, target))
    return meta ~= nil and meta.file == ui.document.file
end

--- CREngine 的整本书才能做；章节源、属主源已卸载的不做。
--- 读别的衍生版（双语版、排版版、另一个方向的转换版）时不做：衍生版的划线只会和它的原书收敛，再套一层就回不到笔记库。
---@param ui table
---@param target "simplified"|"traditional"
---@return boolean
function Convert.available(ui, target)
    local session = require("reader.session").current()
    local source = session and session.identity.source
    if source == nil or source.type == "chapter" or ui.rolling == nil then return false end
    return DerivedNote.originOf(ui.document.file) == nil or Convert.active(ui, target)
end

---@param ui table
---@param identity BookIdentity
---@param target "simplified"|"traditional"
local function start(ui, identity, target)
    local Toast = require("ui.themes.widgets.toast")
    local input = prepare(ui, identity, target)
    require("workers.ui.task_dialog").start{
        key = taskKey(identity, target),
        kind = "convert",
        title = T(_("%1（%2）"), identity.book and identity.book.title or "", TARGETS[target].title),
        restartable = true,
        run = task(input),
        on_done = function(result)
            if not result.ok then
                Toast:new{ text = T(_("转换失败：%1"), tostring(result.err):match("[^\n]*")) }:show()
                return
            end
            local reader = require("apps/reader/readerui").instance
            if not (reader and reader.document and reader.document.file == input.origin) then
                Toast:new{ text = _("转换已完成") }:show()
                return
            end
            require("ui.themes.widgets.confirm"):new{
                text = _("转换已完成，现在打开？"),
                ok_text = _("打开"),
                ok_callback = function()
                    Bilingual.switchTo(reader, identity, input.dest, reader.document:getXPointer())
                end,
            }:show()
        end,
    }
end

--- 打开或生成某个方向的转换版：已在读则切回原书；有现成转换版直接打开；正在转换时跟随进度；否则生成。
---@param ui table
---@param target "simplified"|"traditional"
local function run(ui, target)
    local identity = require("reader.session").current().identity
    local meta = DerivedNote.readMeta(workDir(identity, target))
    local xpointer = ui.document:getXPointer()
    if meta and ui.document.file == meta.file then
        Bilingual.switchTo(ui, identity, meta.origin, xpointer)
    elseif meta and meta.origin == ui.document.file then
        Bilingual.switchTo(ui, identity, meta.file, xpointer)
    else
        local running = require("workers.tasks").get(taskKey(identity, target))
        if running then
            require("workers.ui.task_dialog").follow(running)
        else
            start(ui, identity, target)
        end
    end
end

--- 任一方向的转换版正在读。
---@param ui table
---@return boolean
function Convert.activeAny(ui)
    return Convert.active(ui, "traditional") or Convert.active(ui, "simplified")
end

--- 任一方向可做。
---@param ui table
---@return boolean
function Convert.availableAny(ui)
    return Convert.available(ui, "traditional") or Convert.available(ui, "simplified")
end

--- 快捷面板入口：选转简体还是转繁体；正在读转换版时只给切回原书。
---@param ui table
function Convert.show(ui)
    local items = {}
    if Convert.activeAny(ui) then
        local target = Convert.active(ui, "traditional") and "traditional" or "simplified"
        items[1] = { text = _("切换回原书"), callback = function() run(ui, target) end }
    else
        for _idx, target in ipairs({ "simplified", "traditional" }) do
            items[#items + 1] = { text = TARGETS[target].title, callback = function() run(ui, target) end }
        end
    end
    require("ui.themes.widgets.sheet"):new{ title = _("简繁转换"), items = items }:show()
end

return Convert
