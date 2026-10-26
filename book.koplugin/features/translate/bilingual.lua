--[[--
整书双语对照：每段原文下方追加一段译文，生成的双语版放在这本书的缓存工作目录里。

文件（`<书的工作目录>/bilingual/`，随清缓存 / 删书一起清掉）：
- `<engine>-<lang>.jsonl`：译文缓存，一行一个 `[原文, 译文]`，只追加。中断、重试后跳过已译段落，换引擎各存各的。
- `meta.json`：`{ origin, file }`，最近一次生成的双语版与它的原书路径。
- `source.fb2|html`：非 EPUB 由 CREngine 导出的 DOM，生成成功后删除。

格式：EPUB 逐个改写 XHTML，样式与图片原样保留；其余 CREngine 格式导出 DOM，
按根元素写成 .fb2 / .html（TXT 的 DOM 就是 FB2），图片不保留。

身份：双语版是同一本书的另一个文件，books.path 不动（整本书）。开书时按 meta.json 解析回原书身份，
进度、笔记、统计都记在这本书上；上次读的版本记在原书 sidecar（`DerivedNote.remember`），桌面开书时恢复。
译文只追加在原段落内部，原文 xpointer 两版通用，切换时写进目标 sidecar 的 last_xpointer，停在同一段。
章节源仍用 `Store.touch` 登记章节文件。

章节源（`type == "chapter"`）的书按章翻译，见 features.translate.chapter；这里只出面板。

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
            if isHtml(entry.path) then data = Markup.inject(data, map, input.style) end
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
        assert(f:write((Markup.inject(assert(readFile(input.source)), map, input.style))))
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
---@field chapter boolean|nil 章节翻译输入
---@field kind "epub"|"dom"
---@field origin string 原书路径
---@field source string|nil dom：导出的 DOM 文件
---@field cache string 译文缓存
---@field dest string 双语版
---@field dir string
---@field engine "edge"|"ai"
---@field lang string
---@field style string|nil 译文附加样式（`Markup.style`），任务开始时取自设置

--- 任务体：分析 → 翻译缺的段落 → 生成双语版 → 写 meta。返回 run(report, done)，done 恰好一次。
--- run 返回 { cancel }：取消时停掉在途请求与子进程、删半截的 .part；已译段落留在缓存，下次接着翻。
---@param input BilingualInput
---@return fun(report: fun(text: string, count: integer|nil, total: integer|nil), done: fun(result: table)): { cancel: fun() }
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
                -- 章节：原章就是 source，不删也不写 meta（按书开关决定开哪份）。
                if input.chapter then return finish({ ok = true, file = input.dest }) end
                -- job 回调里抛错会被吞掉、finish 不来，前台进度窗就关不掉：写盘失败按任务失败结束。
                local ok, err = pcall(writeFile, input.dir .. "/meta.json",
                    JSON.encode({ origin = input.origin, file = input.dest }))
                if not ok then return finish({ ok = false, err = err }) end
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
                        if not list then return finish({ ok = false, err = err }) end
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
        return { cancel = function()
            halt()
            os.remove(input.dest .. ".part")
        end }
    end
end

--- 把位置与排版写进目标文件的 sidecar 再换文档。DOM 版本跟着原文档走，xpointer 才按同一套规则解析。
---@param ui table ReaderUI
---@param identity BookIdentity
---@param target string
---@param xpointer string
---@param touch_opts table|nil 章节：{ chapter_idx }
local function switchTo(ui, identity, target, xpointer, touch_opts)
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
    if touch_opts then
        local ok, err = require("book.store").touch(target, identity, touch_opts)
        if not ok then
            Toast:new{ text = err }:show()
            return
        end
    else
        local origin = DerivedNote.originOf(ui.document.file) or ui.document.file
        DerivedNote.remember(ui, origin, target ~= origin and target or nil)
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

---@param identity BookIdentity
---@return string
local function taskKey(identity)
    return "bilingual\0" .. identity.source_id .. "\0" .. identity.stable_id
end

--- 整书翻译：入后台任务队列，一本书同时只有一个；前台跟随进度，可取消、可转后台（顶栏看进度）。
--- 关书不影响任务（只读工作目录里的文件）；完成时若还在读原书就询问打开，否则只提示。
--- 失败、取消后重来时已译段落从缓存续上。
---@param ui table
---@param identity BookIdentity
---@param engine "edge"|"ai"
---@param lang string 目标语言
---@param chapter { input: BilingualInput, touch: table }|nil 章节源：只翻本章，完成后重开本章
local function start(ui, identity, engine, lang, chapter)
    local Toast = require("ui.themes.widgets.toast")
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi") }:show()
        return
    end
    local input = chapter and chapter.input or prepare(ui, identity, engine, lang)
    input.style = Markup.style(require("utils.settings").get("features.translate"))
    local run = task(input)
    -- 整书翻译常比自动休眠时长还久。AutoSuspend（Kindle 上是重置 powerd 的 t1）按最后一次 InputEvent 计时：
    -- 每报一次进度就算一次操作，翻译结束自然恢复，不留开关状态。
    local event_hook = require("ui/uimanager").event_hook
    require("workers.ui.task_dialog").start{
        key = taskKey(identity),
        kind = "convert",
        title = T(_("%1（双语）"), identity.book and identity.book.title or ""),
        restartable = true,
        run = function(report, done)
            return run(function(text, count, total)
                event_hook:execute("InputEvent")
                report(text, count, total)
            end, done)
        end,
        on_done = function(result)
            if not result.ok then
                Toast:new{ text = T(_("双语翻译失败：%1"), tostring(result.err):match("[^\n]*")) }:show()
                return
            end
            local reader = require("apps/reader/readerui").instance
            if not (reader and reader.document and reader.document.file == input.origin) then
                Toast:new{ text = _("双语对照已生成") }:show()
                return
            end
            require("ui.themes.widgets.confirm"):new{
                text = _("双语对照已生成，现在打开？"),
                ok_text = _("打开"),
                ok_callback = function()
                    switchTo(reader, identity, input.dest, reader.document:getXPointer(), chapter and chapter.touch)
                end,
            }:show()
        end,
    }
end

--- 正在读双语版（面板按钮高亮）。
---@param ui table
---@return boolean
function Bilingual.active(ui)
    local identity = require("reader.session").current().identity
    if identity.source and identity.source.type == "chapter" then
        return require("features.translate.chapter").get(identity) ~= nil
    end
    local meta = readMeta(workDir(require("reader.session").current().identity))
    return meta ~= nil and meta.file == ui.document.file
end

--- CREngine 文档才能做（章节源按章做，漫画 CBZ 不是 CREngine）；属主源已卸载（第三方源插件）的也不做。
--- 读别的衍生版（如排版版）时不做：衍生版的划线只会和它的原书收敛，再套一层就回不到笔记库。
---@param ui table
---@return boolean
function Bilingual.available(ui)
    local session = require("reader.session").current()
    local source = session and session.identity.source
    if source == nil or ui.rolling == nil then return false end
    if source.type == "chapter" then return true end
    return DerivedNote.originOf(ui.document.file) == nil or Bilingual.active(ui)
end

--- 章节源：按书开关。开启后就绪的双语章立即切过去，否则后台翻译；关闭时在双语章上切回原章。
---@param ui table
---@param identity BookIdentity
local function showChapter(ui, identity)
    local running = require("workers.tasks").get(taskKey(identity))
    if running then
        require("workers.ui.task_dialog").follow(running)
        return
    end
    local ChapterBi = require("features.translate.chapter")
    local Paths = require("utils.paths")
    local Languages = require("features.translate.languages")
    local translator = require("ui/translator")
    local lang = translator:getTargetLanguage() --[[@as string]]
    local origin = Paths.chapterOrigin(ui.document.file)
    local touch = { chapter_idx = tonumber(identity.chapter_idx) }
    local items = {
        { text = T(_("目标语言：%1"), Languages.displayName(translator, lang)), callback = function()
            Languages.pick(translator, _("目标语言"), false, lang, function(code)
                Languages.applyTarget(code)
                Bilingual.show(ui)
            end)
        end },
    }
    -- 与整书同一流程：本章双语章就绪直接切过去，否则进度窗翻译本章（可转后台），完成询问重开。
    local function enable(engine)
        local conf = { engine = engine, lang = lang }
        ChapterBi.set(identity, conf)
        local dest = touch.chapter_idx and ChapterBi.resolve(identity, touch.chapter_idx, origin)
        if dest then
            if dest ~= ui.document.file then
                switchTo(ui, identity, dest, originalXPointer(ui.document, ui.document:getXPointer()), touch)
            end
            return
        end
        start(ui, identity, engine, lang, { input = ChapterBi.input(identity, origin, conf), touch = touch })
    end
    if ChapterBi.get(identity) then
        items[#items + 1] = { text = _("关闭双语对照"), callback = function()
            ChapterBi.set(identity, nil)
            if origin ~= ui.document.file then
                switchTo(ui, identity, origin, originalXPointer(ui.document, ui.document:getXPointer()), touch)
            end
        end }
    end
    items[#items + 1] = { text = _("用 Edge 开启双语对照"), callback = function() enable("edge") end }
    local ai = require("ai").isConfigured()
    items[#items + 1] = {
        text = ai and _("用 AI 开启双语对照") or _("用 AI 开启双语对照（未配置 AI）"),
        enabled = ai,
        callback = function() enable("ai") end,
    }
    require("ui.themes.widgets.sheet"):new{ title = _("双语对照"), items = items }:show()
end

--- 快捷面板入口：读双语版时直接切回原文；这本书正在翻译时跟随进度；
--- 否则选择打开已有双语版或用某个引擎翻译全书。
---@param ui table
function Bilingual.show(ui)
    local identity = require("reader.session").current().identity
    if identity.source and identity.source.type == "chapter" then return showChapter(ui, identity) end
    local running = require("workers.tasks").get(taskKey(identity))
    local meta = readMeta(workDir(identity))
    local xpointer = ui.document:getXPointer()
    if meta and ui.document.file == meta.file then
        switchTo(ui, identity, meta.origin, originalXPointer(ui.document, xpointer))
        return
    end
    if running then
        require("workers.ui.task_dialog").follow(running)
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

Bilingual.switchTo = switchTo
Bilingual.ENGINES = ENGINES
Bilingual._appendCache = appendCache
Bilingual._batches = batches
Bilingual._task = task
Bilingual._originalXPointer = originalXPointer

return Bilingual
