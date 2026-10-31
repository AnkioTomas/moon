--[[--
从正在阅读的文档里取出纯文本，供重排转 EPUB。

流式文档（CREngine：EPUB/FB2/HTML/MOBI/AZW3/DOC/RTF/CHM…）：优先整棵 DOM 一次倒出
（``getHTMLFromXPointer(".0")``，与双语对照同一条路），剥成纯文本；失败再退回逐页
取相邻 XPointer。固定版式（PDF/DjVu）只能逐页取文字层；扫描版没有文字层就报错。

文档对象只在主进程里，取字只能在 UI 线程上做。逐页路径按时长分批、批间让出输入；
DOM 路径是一次同步调用，前后用 scheduleIn 让出，取消只能挡在调用前后。
结果交给 text2epub 做章节识别与物理行合并；转换有损，不保留图片、脚注和原样式。

给了 opts.dir 时落在工作目录（`extract.txt.part` + `extract.cursor`）：逐页路径取消 /
休眠可续；DOM 路径不写页断点（整棵倒出比续跑一万页快）。整本取完改名为 `extract.txt`。
没给 dir 时仍用缓存临时文件（X-Ray 等调用方）。

@module koplugin.book.features.reflow.extract
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Perf = require("utils.perf")
local Text = require("utils.text")
local Paths = require("utils.paths")
local JSON = require("json")
local _ = require("gettext")

local Extract = {}

--- 一批取字的时长上限（毫秒）。原 100 在长书上批次数爆炸；280 仍能让出输入。
local BATCH_MS = 280
--- 批间延迟（秒），必须为正：UIManager:handleInput 会把 nextTick 链一口气跑完、中间不轮询输入。
local YIELD_S = 0.01
--- 每 N 批做一次完整 GC。step 不够：CREngine 取字垃圾在 Kindle 上会越积越少可用内存。
local FULL_GC_EVERY = 8
--- 与双语对照相同：块级节点换行，方便剥成纯文本后识别章节。
local DOM_HTML_FLAGS = 0x0020
--- 临时文件序号：同一秒内两次提取（前一次取消后立刻重来）不能撞名
local seq = 0

local PART_NAME = "extract.txt.part"
local DONE_NAME = "extract.txt"
local CURSOR_NAME = "extract.cursor"

---@param fn fun()
local function later(fn)
    UIManager:scheduleIn(YIELD_S, require("ui.guard").wrap("reflow extract", fn))
end

---@param dir string
---@return string part
---@return string done
---@return string cursor
local function paths(dir)
    return dir .. "/" .. PART_NAME, dir .. "/" .. DONE_NAME, dir .. "/" .. CURSOR_NAME
end

--- 清掉工作目录里的提取断点与成品 txt（「重新排版」时用）。
---@param dir string
function Extract.clearCheckpoint(dir)
    local part, done, cursor = paths(dir)
    os.remove(part)
    os.remove(done)
    os.remove(cursor)
end

--- 已完整取完的正文路径；没有或不在盘上返回 nil。
---@param dir string
---@return string|nil
function Extract.donePath(dir)
    local _part, done = paths(dir)
    return require("libs/libkoreader-lfs").attributes(done, "mode") == "file" and done or nil
end

--- 有未完成断点（取消 / 休眠留下的）。仅逐页路径会留下。
---@param dir string
---@return boolean
function Extract.hasCheckpoint(dir)
    local part, _done, cursor = paths(dir)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(part, "mode") == "file" and lfs.attributes(cursor, "mode") == "file"
end

---@param cursor_path string
---@param done integer
---@param total integer
---@param tail string
local function saveCursor(cursor_path, done, total, tail)
    local f = io.open(cursor_path, "wb")
    if not f then return end
    f:write(JSON.encode({ done = done, total = total, tail = tail }))
    f:close()
end

---@param cursor_path string
---@return table|nil
local function loadCursor(cursor_path)
    local f = io.open(cursor_path, "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(JSON.decode, raw or "")
    if not ok or type(data) ~= "table" then return nil end
    if type(data.done) ~= "number" or type(data.total) ~= "number" then return nil end
    return data
end

--- 断点已取完的页数。正文已齐返回 ``page_count``；没有可用断点返回 0。
---@param dir string
---@param page_count integer 当前文档页数（页数变了断点作废）
---@return integer
function Extract.donePages(dir, page_count)
    page_count = tonumber(page_count) or 0
    if page_count < 1 then return 0 end
    if Extract.donePath(dir) then return page_count end
    if not Extract.hasCheckpoint(dir) then return 0 end
    local _part, _done, cursor_path = paths(dir)
    local data = loadCursor(cursor_path)
    if data and data.total == page_count and data.done > 0 and data.done < page_count then
        return data.done
    end
    return 0
end

--- 流式文档能否整棵 DOM 倒出（有接口即可试；失败再退逐页）。
---@param ui table ReaderUI
---@return boolean
function Extract.canDumpDom(ui)
    return ui.rolling ~= nil and type(ui.document.getHTMLFromXPointer) == "function"
end

--- 相对上一页去重边界行，写入文件。
--- 返回值 previous 只留末行：去重只靠它，整页挂在闭包里会让长书取字越跑可用内存越少。
---@param file file*
---@param previous string 上一页末行（或空）
---@param raw string
---@return string previous_tail
---@return boolean wrote
---@return string|nil err 写盘失败原因
local function appendPage(file, previous, raw)
    local page = Text.normalizeNewlines(raw):gsub("^\n+", ""):gsub("\n+$", "")
    if page == "" then
        return previous, false
    end
    if previous ~= "" then
        local first_line, rest = page:match("^([^\n]+)\n(.*)$")
        if not first_line then
            first_line, rest = page, ""
        end
        if first_line == previous then
            page = rest
        end
    end
    if page == "" then
        return previous, false
    end
    -- 磁盘满 / 卡被拔时 write 返回 nil, err；不查就是交出半本书
    local ok, err = file:write(previous ~= "" and "\n" or "", page)
    if not ok then
        return previous, false, err
    end
    local tail = page:match("^.*\n([^\n]+)$") or page
    return tail, page:find("%S") ~= nil
end

--- 流式文档第 page 页：非末页取相邻两页 xpointer 之间，末页只能跳过去按屏幕范围取。
---@param document table
---@param page integer
---@param count integer
---@return string|nil
local function rollingPage(document, page, count)
    if page < count then
        return document:getTextFromXPointers(document:getPageXPointer(page), document:getPageXPointer(page + 1))
    end
    document:gotoPage(page)
    local Screen = require("device").screen
    local range = document:getTextFromPositions(
        { x = 0, y = 0 }, { x = Screen:getWidth(), y = Screen:getHeight() }, true)
    return range and range.text
end

--- 固定版式第 page 页：词框按行拼接；相邻两词都是 ASCII 才补空格，中日韩文字不加。
---@param document table
---@param page integer
---@return string
local function pagingPage(document, page)
    local lines = {}
    for _line_idx, line in ipairs(document:getPageTextBoxes(page) or {}) do
        local words, previous = {}, nil
        for _word_idx, box in ipairs(line) do
            local word = box.word
            if word and word ~= "" then
                if previous and previous:match("[%w%p]$") and word:match("^%w") then
                    words[#words + 1] = " "
                end
                words[#words + 1] = word
                previous = word
            end
        end
        lines[#lines + 1] = table.concat(words)
    end
    return table.concat(lines, "\n")
end

--- 整棵 DOM → 纯文本。失败返回 nil（调用方退逐页）。
---@param document table
---@return string|nil
local function dumpDomText(document)
    local ok, html = pcall(document.getHTMLFromXPointer, document, ".0", DOM_HTML_FLAGS)
    if not ok or type(html) ~= "string" or html == "" then return nil end
    -- 双语对照同一套：去掉 CREngine 根包装再剥标签。
    html = html:gsub("^%s*<RootNode[^>]*>", ""):gsub("</RootNode>%s*$", "")
    local text = Text.stripHtml(html)
    html = nil
    collectgarbage("collect")
    if text == "" or not text:find("%S") then return nil end
    return text
end

--- 取出 ui 当前文档的全部文字到文件；成功 cb(path)，失败 cb(nil, err)。
--- opts.dir：工作目录，启用断点；否则写缓存临时文件（取消即删）。
--- 成功时文件归调用方（工作目录成品可留给下次跳过取字）；取消 / 硬失败行为见上。
---@param ui table ReaderUI
---@param cb fun(path: string|nil, err: any)
---@param on_progress fun(text: string, done: integer, total: integer) 每批结束报一次已取页数
---@param opts { dir: string }|nil
---@return { cancel: fun() }
function Extract.run(ui, cb, on_progress, opts)
    local document = ui.document
    local rolling = ui.rolling ~= nil
    local count = document:getPageCount()
    -- 末页 gotoPage 会搬走阅读位置，收尾时放回（仅逐页末页路径会挪）。
    local restore_xp = rolling and document:getXPointer() or nil
    local cancelled = false
    local dir = opts and opts.dir
    local part_path, done_path, cursor_path
    local start_page = 1
    local previous = ""
    local had_text = false
    local mode = "wb"
    local try_dom = Extract.canDumpDom(ui)

    if dir then
        Paths.ensureDir(dir)
        local existing = Extract.donePath(dir)
        if existing then
            on_progress(_("正在提取文字"), 1, 1)
            cb(existing)
            return { cancel = function() end }
        end
        part_path, done_path, cursor_path = paths(dir)
        if try_dom then
            -- DOM 不认旧页断点：整棵倒出比续跑快；清掉以免残留半截。
            os.remove(part_path)
            os.remove(cursor_path)
            cursor_path = nil
        else
            local cursor = loadCursor(cursor_path)
            local lfs = require("libs/libkoreader-lfs")
            if cursor and cursor.total == count and cursor.done > 0 and cursor.done < count
                and lfs.attributes(part_path, "mode") == "file" then
                start_page = cursor.done + 1
                previous = type(cursor.tail) == "string" and cursor.tail or ""
                had_text = previous ~= ""
                mode = "ab"
            else
                os.remove(part_path)
                os.remove(cursor_path)
            end
        end
    else
        Paths.ensureCacheRoot()
        seq = seq + 1
        part_path = Paths.cacheDir() .. "/reflow_extract_" .. os.time() .. "_" .. seq .. ".txt"
    end

    ---@param err any
    local function fail(err)
        os.remove(part_path)
        if cursor_path then os.remove(cursor_path) end
        if ui.document == document and restore_xp then
            local ok, restore_err = pcall(document.gotoXPointer, document, restore_xp)
            if not ok then require("logger").warn("reflow extract: restore position failed", restore_err) end
        end
        cb(nil, err)
    end

    ---@param path string
    local function succeed(path)
        if ui.document == document and restore_xp then
            local ok, restore_err = pcall(document.gotoXPointer, document, restore_xp)
            if not ok then require("logger").warn("reflow extract: restore position failed", restore_err) end
        end
        cb(path)
    end

    --- 把全文写入成品路径。
    ---@param text string
    ---@return boolean ok
    local function writeAll(text)
        local file, open_err = io.open(part_path, "wb")
        if not file then
            fail(open_err or _("无法创建临时文件"))
            return false
        end
        local ok, err = file:write(text)
        local close_ok, close_err = file:close()
        if not ok or not close_ok then
            os.remove(part_path)
            fail(_("写入临时文件失败") .. ": " .. tostring(err or close_err))
            return false
        end
        local out = part_path
        if dir then
            os.remove(done_path)
            local renamed, rename_err = os.rename(part_path, done_path)
            if not renamed then
                os.remove(part_path)
                fail(rename_err or _("写入临时文件失败"))
                return false
            end
            out = done_path
        end
        succeed(out)
        return true
    end

    --- 逐页路径（PDF / DOM 失败回退 / 无 DOM 接口）。
    local function runPages()
        local file, open_err = io.open(part_path, mode)
        if not file then
            fail(open_err or _("无法创建临时文件"))
            return
        end
        local closed = false
        local batches = 0
        local reported = -1
        local readPage = rolling and rollingPage or pagingPage

        local function discardTmp()
            if not closed then
                closed = true
                file:close()
            end
            os.remove(part_path)
            if cursor_path then os.remove(cursor_path) end
        end

        local function abandonKeepCheckpoint()
            if not closed then
                closed = true
                file:close()
            end
            if not dir then
                os.remove(part_path)
            end
        end

        ---@param err any
        local function failPages(err)
            discardTmp()
            if ui.document == document and restore_xp then
                local ok, restore_err = pcall(document.gotoXPointer, document, restore_xp)
                if not ok then require("logger").warn("reflow extract: restore position failed", restore_err) end
            end
            cb(nil, err)
        end

        ---@param page integer
        local function step(page)
            if cancelled then
                abandonKeepCheckpoint()
                return
            end
            if ui.document ~= document then return failPages(_("文档已关闭")) end
            local started = Perf.now()
            while page <= count do
                local ok, chunk = pcall(readPage, document, page, count)
                if not ok or type(chunk) ~= "string" then
                    return failPages(_("无法提取文字") .. ": " .. tostring(chunk))
                end
                local wrote, write_err
                previous, wrote, write_err = appendPage(file, previous, chunk)
                chunk = nil
                if write_err then
                    return failPages(_("写入临时文件失败") .. ": " .. tostring(write_err))
                end
                if wrote then had_text = true end
                page = page + 1
                if page <= count and Perf.now() - started >= BATCH_MS then
                    local percent = math.floor((page - 1) * 100 / count)
                    if percent ~= reported then
                        reported = percent
                        on_progress(_("正在提取文字"), page - 1, count)
                    end
                    if cursor_path then
                        saveCursor(cursor_path, page - 1, count, previous)
                    end
                    batches = batches + 1
                    if batches % FULL_GC_EVERY == 0 then
                        collectgarbage("collect")
                    else
                        collectgarbage("step", 800)
                    end
                    return later(function() step(page) end)
                end
            end
            closed = true
            local close_ok, close_err = file:close()
            if not close_ok then
                os.remove(part_path)
                if cursor_path then os.remove(cursor_path) end
                return failPages(_("写入临时文件失败") .. ": " .. tostring(close_err))
            end
            if not had_text then
                os.remove(part_path)
                if cursor_path then os.remove(cursor_path) end
                return failPages(_("文档没有可提取的文字"))
            end
            local out = part_path
            if dir then
                os.remove(done_path)
                local renamed, rename_err = os.rename(part_path, done_path)
                if not renamed then
                    os.remove(part_path)
                    if cursor_path then os.remove(cursor_path) end
                    return failPages(rename_err or _("写入临时文件失败"))
                end
                if cursor_path then os.remove(cursor_path) end
                out = done_path
            end
            succeed(out)
        end

        if start_page > 1 then
            on_progress(_("正在提取文字"), start_page - 1, count)
        end
        later(function() step(start_page) end)
    end

    --- DOM 一次倒出；失败退逐页。
    local function runDom()
        on_progress(_("正在提取文字"), 0, 1)
        later(function()
            if cancelled then
                if not dir then os.remove(part_path) end
                return
            end
            if ui.document ~= document then return fail(_("文档已关闭")) end
            local text = dumpDomText(document)
            if cancelled then
                if not dir then os.remove(part_path) end
                return
            end
            if not text then
                -- 接口在但倒不出字：退回逐页（仍可能有字）。
                return runPages()
            end
            on_progress(_("正在提取文字"), 1, 1)
            writeAll(text)
        end)
    end

    if try_dom then
        runDom()
    else
        runPages()
    end
    return { cancel = function()
        cancelled = true
    end }
end

return Extract
