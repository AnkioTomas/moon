--[[--
整书双语对照：每段原文下方追加一段译文，生成的双语版放在这本书的缓存工作目录里。

文件（`<书的工作目录>/bilingual/`，随清缓存 / 删书一起清掉）：
- `<engine>-<lang>.jsonl`：译文缓存，一行一个 `[原文, 译文]`，只追加。中断、重试后跳过已译段落，换引擎各存各的。
- `<engine>-<lang>.jsonl.pending`：这次要译的原文，一行一个 JSON 字符串。分析在子进程里写，主进程按批读，任务结束删除。不进 worker 帧。
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
local Text = require("utils.text")
local readMeta = DerivedNote.readMeta
local T = require("ffi/util").template
local _ = require("gettext")

local Bilingual = {}
--- 相对书的工作目录。收划线只认这个目录，见 note.derived_dirs。
Bilingual.DIR = "bilingual"

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

---@param value any
---@return string|nil
local function trimAiText(value)
    if type(value) ~= "string" then return nil end
    local text = Text.trim(value)
    if text == "" then return nil end
    return text
end

---@param value any
---@return integer|nil
local function parseAiId(value)
    local id = value
    if type(id) == "string" then id = tonumber(id) end
    if type(id) == "number" and id > 0 and id % 1 == 0 then return id end
    return nil
end

---@class BilingualAiItem
---@field id integer
---@field text string

--- 从 AI 返回里按 id 对齐；条数不够时不按可能错位的顺序填入。
--- 纯字符串且条数与请求一致时仍按顺序（旧协议）。
---@param requested BilingualAiItem[]
---@param items any
---@return table<integer, string>
local function alignAiItems(requested, items)
    local out = {}
    if type(items) ~= "table" or #requested == 0 then return out end
    local by_id = {}
    for _idx, item in ipairs(requested) do
        by_id[item.id] = item
    end
    local as_strings = #items == #requested
    for index = 1, #items do
        local item = items[index]
        if type(item) == "table" then
            as_strings = false
            local id, text = parseAiId(item.id), trimAiText(item.text)
            if id and text and by_id[id] and not out[id] then
                out[id] = text
            end
        elseif type(item) ~= "string" then
            as_strings = false
        end
    end
    if not as_strings then return out end
    for i, item in ipairs(requested) do
        out[item.id] = trimAiText(items[i])
    end
    return out
end

--- AI：每项带 id 与原文，按 id 对齐。能对上的先留下，缺的再补一次；
--- 仍缺的本轮不写入缓存（下次续跑）。整批都没有可用译文才失败。
function ENGINES.ai.translate(texts, lang, cb)
    local name = require("features.translate.languages").displayName(require("ui/translator"), lang)
    local aligned, current, stopped = {}, nil, false

    ---@param ids integer[]
    ---@return BilingualAiItem[]
    local function requestOf(ids)
        local requested = {}
        for _idx, id in ipairs(ids) do
            requested[#requested + 1] = { id = id, text = texts[id] }
        end
        return requested
    end

    ---@return integer[]
    local function missingIds()
        local ids = {}
        for i = 1, #texts do
            if not aligned[i] then ids[#ids + 1] = i end
        end
        return ids
    end

    local function filled()
        local list = {}
        for i = 1, #texts do list[i] = aligned[i] end
        cb(list)
    end

    ---@param err any
    ---@param fallback any
    ---@return string
    local function failReason(err, fallback)
        if type(err) == "string" and err ~= "" then return err end
        if type(fallback) == "string" and fallback ~= "" then return fallback end
        return _("AI 没有返回可用译文")
    end

    ---@param ids integer[]
    ---@param after fun(err: any)
    local function request(ids, after)
        local requested = requestOf(ids)
        local handle
        handle = require("ai").jsonExtract({
            { role = "system", content = "You are a professional book translator. Translate every item in the JSON "
                .. "array `items` into " .. name .. ". Each item has an `id` and `text`. Reply with JSON only: "
                .. '{"items": [{"id": 1, "text": "..."}]}'
                .. " Use the same id for each item. Do not skip, merge, or drop items." },
            { role = "user", content = JSON.encode({ items = requested }) },
        }, { max_tokens = 4000 }, function(result, err)
            if current == handle then current = nil end
            if stopped then return end
            local items = result and result.items
            if items == nil and type(result) == "table" and result[1] ~= nil then
                items = result
            end
            local got = alignAiItems(requested, items)
            for id, text in pairs(got) do
                if not aligned[id] then aligned[id] = text end
            end
            after(err)
        end)
        if current == nil then current = handle end
    end

    local ids = {}
    for i = 1, #texts do ids[i] = i end
    request(ids, function(err)
        if stopped then return end
        local left = missingIds()
        if #left == 0 then
            filled()
            return
        end
        request(left, function(retry_err)
            if stopped then return end
            if #missingIds() == #texts then
                cb(nil, failReason(retry_err, err))
                return
            end
            filled()
        end)
    end)
    return { cancel = function()
        stopped = true
        if current then
            local cancel = current.cancel
            if type(cancel) == "function" then cancel(current) end
        end
    end }
end

---@param identity BookIdentity
---@return string
local function workDir(identity)
    return require("utils.paths").bookWorkDir(identity.stable_id, identity.source_id) .. "/" .. Bilingual.DIR
end

local Fs = require("utils.fs")
local readFile = Fs.read
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
--- 只写入已对齐的非空译文；漏翻的不进缓存，下次续跑再补。
---@param path string
---@param texts string[]
---@param list string[]|nil
---@return integer
local function appendCache(path, texts, list)
    local lines = {}
    for i, text in ipairs(texts) do
        local translated = list and list[i]
        if type(translated) == "string" and translated ~= "" then
            lines[#lines + 1] = JSON.encode({ text, translated })
        end
    end
    if #lines == 0 then return 0 end
    local f = assert(io.open(path, "ab"))
    assert(f:write("\n"))
    for _idx, line in ipairs(lines) do
        assert(f:write(line, "\n"))
    end
    assert(f:close())
    return #lines
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

---@param input BilingualInput
---@return string
local function pendingPath(input)
    return input.cache .. ".pending"
end

--- 子进程：去重后的段落总数，以及缓存里还没有的段落数。
--- 待译原文写进 pending 文件。整本书塞进一条 worker 帧会超过协议 4MB 上限。
---@param input BilingualInput
---@return { pending: integer, total: integer }
local function collect(input)
    local cached = loadCache(input.cache)
    local seen, total, count = {}, 0, 0
    local f = assert(io.open(pendingPath(input), "wb"))
    eachHtml(input, function(html)
        for _idx, block in ipairs(Markup.blocks(html)) do
            local inner = html:sub(block.open, block.close - 1)
            for _point, point in ipairs(Markup.points(inner, input.unit)) do
                if not seen[point.key] then
                    seen[point.key] = true
                    total = total + 1
                    if not cached[point.key] then
                        assert(f:write(JSON.encode(point.key), "\n"))
                        count = count + 1
                    end
                end
            end
        end
    end)
    assert(f:close())
    return { pending = count, total = total }
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
            if isHtml(entry.path) then data = Markup.inject(data, map, input.style, input.unit) end
            assert(writer:addFileFromMemory(entry.path, data, mtime), writer.err)
        end
    end
    reader:close()
    writer:close()
end

--- 双语章比原章深一层（bilingual/）。相对引用改到上一级，锚点和绝对地址不动。
---@param html string
---@return string
local function nestRefs(html)
    local function lift(url)
        if url == "" or url:sub(1, 1) == "#" then return url end
        if url:match("^%a[%w+.-]*:") or url:match("^//") or url:match("^/") or url:match("^%.%./") then
            return url
        end
        return "../" .. url
    end
    html = html:gsub("(src%s*=%s*[\"'])([^\"']*)", function(prefix, url) return prefix .. lift(url) end)
    html = html:gsub("(href%s*=%s*[\"'])([^\"']*)", function(prefix, url) return prefix .. lift(url) end)
    html = html:gsub("(url%s*%(%s*[\"']?)([^\"')]+)", function(prefix, url) return prefix .. lift(url) end)
    return html
end

--- 子进程：按缓存插入译文，写成 input.dest。
---@param input BilingualInput
local function build(input)
    local map = loadCache(input.cache)
    if input.kind == "dom" then
        local html = Markup.inject(assert(readFile(input.source)), map, input.style, input.unit)
        if input.chapter then html = nestRefs(html) end
        assert(Fs.write(input.dest, html))
        return true
    end
    local tmp = input.dest .. ".part"
    rewriteEpub(input, map, tmp)
    os.remove(input.dest)
    assert(os.rename(tmp, input.dest))
    return true
end

--- 按段数与字节数切批。单段超长单独成批（读下一条时放回）。
---@param read fun(): string|nil
---@param size integer
---@param chars integer
---@return fun(): string[]|nil
local function batchIterator(read, size, chars)
    local hold
    return function()
        local batch, count = {}, 0
        while #batch < size do
            local text = hold
            hold = nil
            if text == nil then text = read() end
            if text == nil then break end
            if #batch > 0 and count + #text > chars then
                hold = text
                break
            end
            batch[#batch + 1] = text
            count = count + #text
        end
        if #batch == 0 then return nil end
        return batch
    end
end

--- 主进程按批读 pending 文件。打不开时第三返回值是原因，前两个是空操作。
--- 读到解不开的行就停止读取，第四返回值（读完后调用）给出原因；不能把没译的段当成已完成。
---@param path string
---@param size integer
---@param chars integer
---@return fun(): string[]|nil
---@return fun()
---@return string|nil
---@return fun(): string|nil
local function pendingBatches(path, size, chars)
    local f, open_err = io.open(path, "rb")
    if not f then return function() return nil end, function() end, open_err, function() return nil end end
    local closed = false
    local corrupt = nil
    local function close()
        if closed then return end
        closed = true
        f:close()
    end
    local function read()
        if closed or corrupt then return nil end
        while true do
            local line = f:read("*l")
            -- 空行是 ""，只有 nil 才是读完。
            if line == nil then return nil end
            if line ~= "" then
                local ok, text = pcall(JSON.decode, line)
                if ok and type(text) == "string" then return text end
                corrupt = "pending file corrupt: " .. path
                return nil
            end
        end
    end
    return batchIterator(read, size, chars), close, nil, function() return corrupt end
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
---@field unit "paragraph"|"sentence"|nil 对照粒度，翻译时由用户选择；缺省按段落

--- 任务体：分析 → 翻译缺的段落 → 生成双语版 → 写 meta。返回 run(report, done)，done 恰好一次。
--- run 返回 { cancel }：取消时停掉在途请求与子进程、删半截的 .part 和 pending；已译段落留在缓存，下次接着翻。
---@param input BilingualInput
---@return fun(report: fun(text: string, count: integer|nil, total: integer|nil), done: fun(result: table)): { cancel: fun() }
local function task(input)
    local engine = ENGINES[input.engine]
    return function(report, done)
        local slots, stopped = {}, false
        local close_pending = function() end

        local function halt()
            stopped = true
            for slot in pairs(slots) do slot.handle:cancel() end
            slots = {}
        end

        local function finish(result)
            if stopped then return end
            halt()
            close_pending()
            os.remove(pendingPath(input))
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
                local ok, err = Fs.write(input.dir .. "/meta.json",
                    JSON.encode({ origin = input.origin, file = input.dest }))
                if not ok then return finish({ ok = false, err = err }) end
                if input.source then os.remove(input.source) end
                finish({ ok = true, file = input.dest })
            end)
        end

        report(_("正在分析全书段落"))
        job("bilingual.collect", function() return collect(input) end, function(found)
            local next_batch, close, open_err, corrupt = pendingBatches(pendingPath(input), engine.size, engine.chars)
            if open_err then return finish({ ok = false, err = open_err }) end
            close_pending = close
            local inflight, done_reading = 0, false
            local finished = found.total - found.pending
            local gained, last_err = 0, nil
            local function pump()
                if stopped then return end
                while not stopped and inflight < engine.parallel and not done_reading do
                    local texts = next_batch()
                    if not texts then
                        done_reading = true
                        if corrupt() then return finish({ ok = false, err = corrupt() }) end
                        break
                    end
                    inflight = inflight + 1
                    step(function(settle)
                        return engine.translate(texts, input.lang, settle)
                    end, function(list, err)
                        inflight = inflight - 1
                        local saved = appendCache(input.cache, texts, list)
                        if saved > 0 then
                            gained = gained + saved
                            finished = finished + saved
                            report(_("正在翻译…"), finished, found.total)
                        elseif err then
                            last_err = err
                        end
                        pump()
                    end)
                end
                if not stopped and done_reading and inflight == 0 then
                    close_pending()
                    -- 这一轮完全没有新译文才失败；有一部分已译就生成双语版，漏的下次续跑。
                    if found.pending > 0 and gained == 0 then
                        return finish({ ok = false, err = last_err or _("AI 没有返回可用译文") })
                    end
                    produce()
                end
            end
            report(_("正在翻译…"), finished, found.total)
            pump()
        end)
        return { cancel = function()
            halt()
            close_pending()
            os.remove(input.dest .. ".part")
            os.remove(pendingPath(input))
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
    -- 整本 DOM 在主线程上：只切一次 RootNode 包装、头部分开写，不再多拷整串。
    local html = ui.document:getHTMLFromXPointer(".0", 0x0020)
    local first = html:match("^%s*<RootNode[^>]*>()") or 1
    local last = html:match("()</RootNode>%s*$") or #html + 1
    local ext = html:find("^%s*<FictionBook", first) and "fb2" or "html"
    input.kind = "dom"
    input.source = dir .. "/source." .. ext
    input.dest = dir .. "/book." .. ext
    local tmp = input.source .. ".part"
    local f = assert(io.open(tmp, "wb"))
    assert(f:write('<?xml version="1.0" encoding="UTF-8"?>\n', html:sub(first, last - 1)))
    assert(f:close())
    assert(os.rename(tmp, input.source))
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
---@param unit "paragraph"|"sentence"|nil 这次翻译的对照粒度，缺省按段落
local function start(ui, identity, engine, lang, chapter, unit)
    local Toast = require("ui.themes.widgets.toast")
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi") }:show()
        return
    end
    local input = chapter and chapter.input or prepare(ui, identity, engine, lang)
    local translate = require("utils.settings").get("features.translate")
    input.style = Markup.style(translate)
    input.unit = unit == "sentence" and "sentence" or nil
    local run = task(input)
    require("workers.ui.task_dialog").start{
        key = taskKey(identity),
        kind = "convert",
        title = T(_("%1（双语）"), identity.book and identity.book.title or ""),
        restartable = true,
        run = function(report, done)
            return run(function(text, count, total)
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

--- 翻译前的表单：语言、对照方式、引擎当场选，点「开始」才翻。对照方式不进设置。
---@param opts { lang: string, translator: table, languages: table, embed: boolean|nil, can_clear: fun(): boolean|nil, on_clear: fun(page: table)|nil, on_open: fun()|nil, on_close: fun()|nil, on_start: fun(engine: string, lang: string, unit: string) }
local function openForm(opts)
    local lang = opts.lang
    local unit = "paragraph"
    local ai = require("ai").isConfigured()
    local engines = {}
    if opts.embed then engines[#engines + 1] = { value = "embed", text = _("书中译文") } end
    engines[#engines + 1] = { value = "edge", text = "Edge" }
    if ai then engines[#engines + 1] = { value = "ai", text = _("AI") } end
    local engine = engines[1].value
    require("ui.themes.widgets.settings"):new{
        title = _("双语对照"),
        items = function(page)
            local items = {
                {
                    title = _("目标语言"),
                    items = opts.languages.pickerItems(opts.translator, false, lang),
                    current = lang,
                    on_select = function(value)
                        if value == "__all__" then
                            opts.languages.pick(opts.translator, _("目标语言"), false, lang, function(code)
                                opts.languages.applyTarget(code)
                                lang = code
                                page:updateView()
                            end)
                            return false
                        end
                        opts.languages.applyTarget(value)
                        lang = value
                    end,
                },
            }
            if engine ~= "embed" then
                items[#items + 1] = {
                    title = _("对照方式"),
                    items = {
                        { value = "paragraph", text = _("按段落") },
                        { value = "sentence", text = _("按句子") },
                    },
                    current = unit,
                    on_select = function(value) unit = value end,
                }
            end
            if #engines > 1 then
                items[#items + 1] = {
                    title = _("翻译引擎"),
                    items = engines,
                    current = engine,
                    on_select = function(value) engine = value end,
                }
            end
            return items
        end,
        buttons = function(page)
            local buttons = { { text = _("取消"), callback = function() page:close() end } }
            if opts.on_open then
                buttons[#buttons + 1] = { text = _("打开"), callback = function()
                    page:close()
                    opts.on_open()
                end }
            end
            if opts.on_close then
                buttons[#buttons + 1] = { text = _("关闭"), callback = function()
                    page:close()
                    opts.on_close()
                end }
            end
            if opts.on_clear and opts.can_clear() then
                buttons[#buttons + 1] = { text = _("清除译文"), callback = function()
                    opts.on_clear(page)
                end }
            end
            buttons[#buttons + 1] = { text = _("开始"), variant = "primary", callback = function()
                page:close()
                opts.on_start(engine, lang, unit)
            end }
            return buttons
        end,
    }:show()
end

--- 章节源：按书开关。按段落且本章已有生成稿就直接打开；按句子则按所选粒度翻译。
--- 没生成稿时默认打开书中译文。点「清除译文」之后，Edge / AI 才按用户选的引擎和粒度现译。
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
    local function openAt(dest)
        if dest and dest ~= ui.document.file then
            switchTo(ui, identity, dest, originalXPointer(ui.document, ui.document:getXPointer()), touch)
        end
    end
    local current = ChapterBi.get(identity)
    openForm{
        lang = lang, translator = translator, languages = Languages,
        embed = ChapterBi.embedFile(origin) ~= nil,
        can_clear = function()
            if ChapterBi.get(identity) ~= nil or ChapterBi.hasGenerated(identity) then return true end
            return not ChapterBi.embedSuppressed(identity) and ChapterBi.embedFile(origin) ~= nil
        end,
        on_clear = function(page)
            ChapterBi.suppressEmbed(identity)
            ChapterBi.clearGenerated(identity)
            ChapterBi.set(identity, nil)
            if ui.document.file ~= origin then openAt(origin) end
            require("ui.themes.widgets.toast"):new{ text = _("译文已清除") }:show()
            page:updateView()
        end,
        on_close = current and function()
            ChapterBi.set(identity, nil)
            ChapterBi.materialize(origin)
            openAt(origin)
        end or nil,
        on_start = function(engine, picked, unit)
            if engine == "embed" then
                ChapterBi.set(identity, { engine = "embed", lang = picked })
                local dest = touch.chapter_idx and ChapterBi.resolve(identity, touch.chapter_idx, origin)
                openAt(dest or origin)
                return
            end
            local conf = { engine = engine, lang = picked }
            if unit == "sentence" then conf.unit = "sentence" end
            ChapterBi.set(identity, conf)
            local dest = touch.chapter_idx and ChapterBi.resolve(identity, touch.chapter_idx, origin)
            if dest and unit ~= "sentence" then
                openAt(dest)
                return
            end
            start(ui, identity, engine, picked, { input = ChapterBi.input(identity, origin, conf), touch = touch }, unit)
        end,
    }
end

--- 快捷面板入口：读双语版时直接切回原文；这本书正在翻译时跟随进度；
--- 否则弹出表单，选好语言、对照方式和引擎后开始。
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
    openForm{
        lang = translator:getTargetLanguage() --[[@as string]],
        translator = translator, languages = Languages,
        on_open = meta and meta.origin == ui.document.file and function()
            switchTo(ui, identity, meta.file, xpointer)
        end or nil,
        on_start = function(engine, lang, unit)
            start(ui, identity, engine, lang, nil, unit)
        end,
    }
end

Bilingual.switchTo = switchTo
Bilingual.ENGINES = ENGINES
Bilingual._appendCache = appendCache
Bilingual._task = task
Bilingual._pendingBatches = pendingBatches
Bilingual._originalXPointer = originalXPointer
Bilingual._alignAiItems = alignAiItems

return Bilingual
