--[[--
整书双语对照：每段原文下方追加一段译文，生成的双语版放在这本书的缓存工作目录里。

文件（`<书的工作目录>/bilingual/`，随清缓存 / 删书一起清掉）：
- `<engine>-<lang>.jsonl`：译文缓存，一行一个 `[原文, 译文]`，只追加。中断、重试后跳过已译段落，换引擎各存各的。
- `meta.json`：`{ origin, file }`，最近一次生成的双语版与它的原书路径。
- `source.fb2|html`：非 EPUB 由 CREngine 导出的 DOM，生成成功后删除。

格式：EPUB 逐个改写 XHTML，样式与图片原样保留；其余 CREngine 格式导出 DOM，
按根元素写成 .fb2 / .html（TXT 的 DOM 就是 FB2），图片不保留。

身份：双语版是同一本书的另一个文件。切换前 `Store.touch` 把 books.path 指过去，
开书时按路径解析回同一身份，进度、笔记、统计都记在这本书上。译文只追加在原段落内部，
原文 xpointer 两版通用，切换时写进目标 sidecar 的 last_xpointer，停在同一段。
books.path 即用户最后选的版本：复用 books.path 的源从桌面重开仍是双语版，本地书总开原书；
双语版在缓存目录里，清缓存会连它一起删掉并撤 path，下次开书由源重新登记原书。

章节源（`type == "chapter"`）的书不做：章节文件各自独立，没有整本可译。

@module koplugin.book.features.translate.bilingual
--]]

require("l10n").apply()

local DerivedNote = require("reader.session.derived_note")
local JSON = require("json")
local Markup = require("features.translate.markup")
local readMeta = DerivedNote.readMeta
local T = require("ffi/util").template
local _ = require("gettext")

local Bilingual = {}

--- 每次请求的段数、字符数上限与并发数。AI 输出要逐条对齐，批小一些。
local ENGINES = {
    edge = { size = 40, chars = 4000, parallel = 3 },
    ai = { size = 20, chars = 2000, parallel = 2 },
}

--- Edge：一次请求一个字符串数组，源语言自动检测。
function ENGINES.edge.translate(texts, lang, cb)
    return require("features.translate.edge").translateListAsync(texts, lang, nil, function(list, _detected, err)
        cb(list, err)
    end)
end

--- AI：JSON 数组进、JSON 数组出，条数对不上整批作废重试。
function ENGINES.ai.translate(texts, lang, cb)
    local name = require("features.translate.languages").displayName(require("ui/translator"), lang)
    return require("ai").jsonExtract({
        { role = "system", content = "You are a professional book translator. Translate every string in the JSON "
            .. "array `items` into " .. name .. ". Keep the order and the number of items. Reply with JSON only: "
            .. '{"items": ["...", "..."]}' },
        { role = "user", content = JSON.encode({ items = texts }) },
    }, { max_tokens = 4000 }, function(result, err)
        local items = result and result.items
        if type(items) ~= "table" or #items ~= #texts then
            cb(nil, err or "AI returned mismatched items")
            return
        end
        for _idx, item in ipairs(items) do
            if type(item) ~= "string" then
                cb(nil, "AI returned non-text item")
                return
            end
        end
        cb(items)
    end)
end

---@param identity BookIdentity
---@return string
local function workDir(identity)
    return require("utils.paths").bookWorkDir(identity.stable_id, identity.source_id) .. "/bilingual"
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
--- 译文缓存（子进程读）：最后一行可能是被杀时写了一半，解不出来就丢掉这一行。
---@param path string
---@return table<string, string>
local function loadCache(path)
    local map = {}
    local f = io.open(path, "rb")
    if not f then return map end
    for line in f:lines() do
        local ok, pair = pcall(JSON.decode, line)
        if ok and type(pair) == "table" then map[pair[1]] = pair[2] end
    end
    f:close()
    return map
end

--- 先补一个换行：上次被杀时留下的残行不能和这批第一条粘在一起（空行读时丢掉）。
---@param path string
---@param texts string[]
---@param list string[]
local function appendCache(path, texts, list)
    local f = assert(io.open(path, "ab"))
    assert(f:write("\n"))
    for i, text in ipairs(texts) do
        assert(f:write(JSON.encode({ text, list[i] }), "\n"))
    end
    assert(f:close())
end

---@param path string
---@return boolean
local function isHtml(path)
    local ext = path:lower():match("%.(%w+)$")
    return ext == "xhtml" or ext == "html" or ext == "htm"
end

--- 依次交出待处理的每份 HTML（子进程）：EPUB 是包内各 XHTML，其余是导出的 DOM。
---@param input BilingualInput
---@param fn fun(html: string)
local function eachHtml(input, fn)
    if input.kind == "dom" then
        fn(assert(readFile(input.source)))
        return
    end
    local reader = require("ffi/archiver").Reader:new()
    assert(reader:open(input.origin), reader.err)
    for entry in reader:iterate() do
        if entry.mode == "file" and isHtml(entry.path) then
            fn(assert(reader:extractToMemory(entry.path), reader.err))
        end
    end
    reader:close()
end

--- 子进程：去重后的段落总数，以及缓存里还没有的段落。
---@param input BilingualInput
---@return { pending: string[], total: integer }
local function collect(input)
    local cached = loadCache(input.cache)
    local seen, pending, total = {}, {}, 0
    eachHtml(input, function(html)
        for _idx, block in ipairs(Markup.blocks(html)) do
            if not seen[block.text] then
                seen[block.text] = true
                total = total + 1
                if not cached[block.text] then pending[#pending + 1] = block.text end
            end
        end
    end)
    return { pending = pending, total = total }
end

--- 子进程：EPUB 逐项复制，XHTML 插入译文；mimetype 必须是第一项且不压缩。
---@param input BilingualInput
---@param map table<string, string>
---@param dest string
local function rewriteEpub(input, map, dest)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    assert(reader:open(input.origin), reader.err)
    local writer = Archiver.Writer:new()
    os.remove(dest)
    assert(writer:open(dest, "epub"), writer.err)
    local mtime = os.time()
    writer:setZipCompression("store")
    assert(writer:addFileFromMemory("mimetype", "application/epub+zip", mtime), writer.err)
    writer:setZipCompression("deflate")
    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= "mimetype" then
            local data = assert(reader:extractToMemory(entry.path), reader.err)
            if isHtml(entry.path) then data = Markup.inject(data, map) end
            assert(writer:addFileFromMemory(entry.path, data, mtime), writer.err)
        end
    end
    reader:close()
    writer:close()
end

--- 子进程：按缓存插入译文，写成 input.dest。
---@param input BilingualInput
local function build(input)
    local map = loadCache(input.cache)
    local tmp = input.dest .. ".part"
    if input.kind == "dom" then
        local f = assert(io.open(tmp, "wb"))
        assert(f:write((Markup.inject(assert(readFile(input.source)), map))))
        assert(f:close())
    else
        rewriteEpub(input, map, tmp)
    end
    os.remove(input.dest)
    assert(os.rename(tmp, input.dest))
    return true
end

---@param texts string[]
---@param size integer
---@param chars integer
---@return string[][]
local function batches(texts, size, chars)
    local out, current, count = {}, {}, 0
    for _idx, text in ipairs(texts) do
        if #current > 0 and (#current >= size or count + #text > chars) then
            out[#out + 1] = current
            current, count = {}, 0
        end
        current[#current + 1] = text
        count = count + #text
    end
    if #current > 0 then out[#out + 1] = current end
    return out
end

---@class BilingualInput
---@field kind "epub"|"dom"
---@field origin string 原书路径
---@field source string|nil dom：导出的 DOM 文件
---@field cache string 译文缓存
---@field dest string 双语版
---@field dir string
---@field engine "edge"|"ai"
---@field lang string

--- 任务体：分析 → 翻译缺的段落 → 生成双语版 → 写 meta。返回 Tasks 要的 run。
---@param input BilingualInput
---@return fun(report: function, done: fun(result: table)): { cancel: fun() }
local function task(input)
    local engine = ENGINES[input.engine]
    return function(report, done)
        local slots, stopped = {}, false

        local function halt()
            stopped = true
            for slot in pairs(slots) do slot.handle:cancel() end
            slots = {}
        end

        local function finish(result)
            if stopped then return end
            halt()
            done(result)
        end

        --- 起一个异步步骤；回调可能同步到达，所以先记 done 再决定要不要登记句柄。
        local function step(start, cb)
            local slot = {}
            slot.handle = start(function(...)
                slot.done = true
                slots[slot] = nil
                if not stopped then cb(...) end
            end)
            if not slot.done and slot.handle then slots[slot] = true end
        end

        local function job(name, fn, cb)
            step(function(settle)
                return require("workers.job").run(fn, {
                    name = name,
                    kind = "heavy",
                    on_done = function(result) settle(result) end,
                    on_failed = function(err) settle(nil, err) end,
                })
            end, function(result, err)
                if result == nil then return finish({ ok = false, err = err }) end
                cb(result)
            end)
        end

        local function produce()
            report(_("正在生成双语版"))
            job("bilingual.build", function() return build(input) end, function()
                writeFile(input.dir .. "/meta.json", JSON.encode({ origin = input.origin, file = input.dest }))
                if input.source then os.remove(input.source) end
                finish({ ok = true, file = input.dest })
            end)
        end

        report(_("正在分析全书段落"))
        job("bilingual.collect", function() return collect(input) end, function(found)
            local queue = batches(found.pending, engine.size, engine.chars)
            local next_idx, inflight = 1, 0
            local finished = found.total - #found.pending
            local function pump()
                if next_idx > #queue and inflight == 0 then return produce() end
                while not stopped and inflight < engine.parallel and next_idx <= #queue do
                    local texts = queue[next_idx]
                    next_idx, inflight = next_idx + 1, inflight + 1
                    step(function(settle)
                        return engine.translate(texts, input.lang, settle)
                    end, function(list, err)
                        inflight = inflight - 1
                        if not list then return finish({ ok = false, err = err, retry = true }) end
                        appendCache(input.cache, texts, list)
                        finished = finished + #texts
                        report(_("正在翻译…"), finished, found.total)
                        pump()
                    end)
                end
            end
            report(_("正在翻译…"), finished, found.total)
            pump()
        end)

        return { cancel = halt }
    end
end

--- 把位置与排版写进目标文件的 sidecar 再换文档。DOM 版本跟着原文档走，xpointer 才按同一套规则解析。
---@param ui table ReaderUI
---@param identity BookIdentity
---@param target string
---@param xpointer string
local function switchTo(ui, identity, target, xpointer)
    local Toast = require("ui.themes.widgets.toast")
    if require("libs/libkoreader-lfs").attributes(target, "mode") ~= "file" then
        Toast:new{ text = _("文件不存在") }:show()
        return
    end
    local Prefs = require("reader.prefs")
    local settings = require("docsettings"):open(target)
    local prefs = Prefs.capture(ui)
    if prefs then Prefs.write(settings, prefs) end
    settings:saveSetting("last_xpointer", xpointer)
    settings:saveSetting("cre_dom_version", ui.doc_settings:readSetting("cre_dom_version"))
    settings:flush()
    local ok, err = require("book.store").touch(target, identity)
    if not ok then
        Toast:new{ text = err }:show()
        return
    end
    ui:switchDocument(target)
end

--- 双语版里的位置落在译文上时退到所在段落：译文元素原书里没有。
---@param document table
---@param xpointer string
---@return string
local function originalXPointer(document, xpointer)
    local prefix = '<span class="' .. Markup.CLASS .. '"'
    for at, segment in xpointer:gmatch("()/(span[%[%d%]]*)") do
        local html = document:getHTMLFromXPointer(xpointer:sub(1, at - 1) .. "/" .. segment, 0)
        if html and html:sub(1, #prefix) == prefix then
            return xpointer:sub(1, at - 1)
        end
    end
    return xpointer
end

--- 准备任务输入；非 EPUB 此刻从打开的文档导出 DOM（只有这时手里有文档）。
---@param ui table
---@param identity BookIdentity
---@param engine "edge"|"ai"
---@param lang string
---@return BilingualInput
local function prepare(ui, identity, engine, lang)
    local dir = workDir(identity)
    local Paths = require("utils.paths")
    Paths.ensureBookWork(identity.stable_id, identity.source_id)
    assert(Paths.ensureDir(dir))
    local origin = ui.document.file
    local input = {
        kind = "epub",
        origin = origin,
        cache = dir .. "/" .. engine .. "-" .. lang .. ".jsonl",
        dest = dir .. "/book.epub",
        dir = dir,
        engine = engine,
        lang = lang,
    }
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

--- 入队整书翻译；同一本书已有任务在跑时直接提示，不去覆盖它正在读的导出文件。
---@param ui table
---@param identity BookIdentity
---@param engine "edge"|"ai"
---@param lang string 目标语言
local function start(ui, identity, engine, lang)
    local Toast = require("ui.themes.widgets.toast")
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi") }:show()
        return
    end
    local TaskDialog = require("workers.ui.task_dialog")
    local spec = {
        key = "bilingual\0" .. identity.source_id .. "\0" .. identity.stable_id,
        kind = "cache",
        title = T(_("%1（双语）"), identity.book and identity.book.title or ""),
        restartable = true,
        cancelable = false,
        retryable = function(result) return result.retry == true end,
    }
    local existing = require("workers.tasks").get(spec.key)
    if existing and existing.state ~= "queued" then
        TaskDialog.rejected("running", spec)
        return
    end
    local input = prepare(ui, identity, engine, lang)
    spec.run = task(input)
    spec.on_done = function(result)
        if not result.ok then
            Toast:new{ text = T(_("双语翻译失败：%1"), tostring(result.err):match("[^\n]*")) }:show()
            return
        end
        local reader = require("apps/reader/readerui").instance
        local session = require("reader.session").current()
        local current = session and session.identity
        if not (reader and current and current.source_id == identity.source_id
                and current.stable_id == identity.stable_id and reader.document.file == input.origin) then
            Toast:new{ text = _("双语对照已生成，可在阅读快捷面板打开") }:show()
            return
        end
        require("ui.themes.widgets.confirm"):new{
            text = _("双语对照已生成，现在打开？"),
            ok_text = _("打开"),
            ok_callback = function()
                switchTo(reader, current, input.dest, reader.document:getXPointer())
            end,
        }:show()
    end
    TaskDialog.start(spec)
end

--- 正在读双语版（面板按钮高亮）。
---@param ui table
---@return boolean
function Bilingual.active(ui)
    local meta = readMeta(workDir(require("reader.session").current().identity))
    return meta ~= nil and meta.file == ui.document.file
end

--- 整书 CREngine 文档才能做；章节源的书（含全本缓存后的）一律不做；属主源已卸载（第三方源插件）的也不做。
--- 读别的衍生版（如排版版）时不做：衍生版的划线只会和它的原书收敛，再套一层就回不到笔记库。
---@param ui table
---@return boolean
function Bilingual.available(ui)
    local session = require("reader.session").current()
    local source = session and session.identity.source
    if source == nil or source.type == "chapter" or ui.rolling == nil then return false end
    return DerivedNote.originOf(ui.document.file) == nil or Bilingual.active(ui)
end

--- 快捷面板入口：读双语版时直接切回原文；读原文时选择打开已有双语版或用某个引擎翻译全书。
---@param ui table
function Bilingual.show(ui)
    local identity = require("reader.session").current().identity
    local meta = readMeta(workDir(identity))
    local xpointer = ui.document:getXPointer()
    if meta and ui.document.file == meta.file then
        switchTo(ui, identity, meta.origin, originalXPointer(ui.document, xpointer))
        return
    end
    local Languages = require("features.translate.languages")
    local translator = require("ui/translator")
    local lang = translator:getTargetLanguage() --[[@as string]]
    local items = {
        { text = T(_("目标语言：%1"), Languages.displayName(translator, lang)), callback = function()
            Languages.pick(translator, _("目标语言"), false, lang, function(code)
                Languages.applyTarget(code)
                Bilingual.show(ui)
            end)
        end },
    }
    if meta and meta.origin == ui.document.file then
        items[#items + 1] = { text = _("打开双语对照"), callback = function()
            switchTo(ui, identity, meta.file, xpointer)
        end }
    end
    items[#items + 1] = { text = _("用 Edge 翻译全书"), callback = function() start(ui, identity, "edge", lang) end }
    local ai = require("ai").isConfigured()
    items[#items + 1] = {
        text = ai and _("用 AI 翻译全书") or _("用 AI 翻译全书（未配置 AI）"),
        enabled = ai,
        callback = function() start(ui, identity, "ai", lang) end,
    }
    require("ui.themes.widgets.sheet"):new{ title = _("双语对照"), items = items }:show()
end

Bilingual._batches = batches
Bilingual._task = task
Bilingual._originalXPointer = originalXPointer

return Bilingual
