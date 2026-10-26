--[[--
从正在阅读的文档里逐页取纯文本，供重排转 EPUB。

流式文档（CREngine：EPUB/FB2/HTML/MOBI/AZW3/DOC/RTF/CHM…）没有整本导出接口：前 N-1 页取相邻页
XPointer 之间的文本，末页跳到页首后按屏幕范围取，取完放回阅读位置。
固定版式（PDF/DjVu）逐页取文字层，按行拼词；扫描版没有文字层，取不到就报错。
文档对象只在主进程里，取字只能在 UI 线程上做：按时长分批，批间让出给输入。结果交给 text2epub
做章节识别与物理行合并；转换有损，不保留图片、脚注和原样式。

页文本边取边写入临时文件，只保留上一页做边界行去重；成功时把文件路径交给调用方，
**绝不**再 read("*a") 整本回主进程——Kindle 上文档已占一大块，再叠一份全文再 fork 必 OOM。

@module koplugin.book.features.reflow.extract
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Perf = require("utils.perf")
local Text = require("utils.text")
local Paths = require("utils.paths")
local _ = require("gettext")

local Extract = {}

--- 一批取字的时长上限（毫秒）。
local BATCH_MS = 100
--- 批间延迟（秒），必须为正：UIManager:handleInput 会把 nextTick 链一口气跑完、中间不轮询输入。
local YIELD_S = 0.01

---@param fn fun()
local function later(fn)
    UIManager:scheduleIn(YIELD_S, require("ui.guard").wrap("reflow extract", fn))
end

--- 相对上一页去重边界行，写入文件；返回新的上一页正文（供下次比较）与是否写入了非空白。
---@param file file*
---@param previous string
---@param raw string
---@return string previous
---@return boolean wrote
local function appendPage(file, previous, raw)
    local page = Text.normalizeNewlines(raw):gsub("^\n+", ""):gsub("\n+$", "")
    if page == "" then
        return previous, false
    end
    if previous ~= "" then
        local last_line = previous:match("^.*\n([^\n]+)$") or previous:match("^[^\n]+$")
        local first_line, rest = page:match("^([^\n]+)\n(.*)$")
        if not first_line then
            first_line, rest = page, ""
        end
        if last_line ~= nil and first_line == last_line then
            page = rest
        end
    end
    if page == "" then
        return previous, false
    end
    if previous ~= "" then
        file:write("\n")
    end
    file:write(page)
    return page, page:find("%S") ~= nil
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

--- 取出 ui 当前文档的全部文字到临时文件；成功 cb(path)，失败 cb(nil, err)。
--- 成功时文件归调用方（用完自己删）；取消 / 失败由这里删掉。可取消，取消后 cb 不再触发。
---@param ui table ReaderUI
---@param cb fun(path: string|nil, err: any)
---@param on_progress fun(text: string, done: integer, total: integer) 每批结束报一次已取页数
---@return { cancel: fun() }
function Extract.run(ui, cb, on_progress)
    local document = ui.document
    local rolling = ui.rolling ~= nil
    local count = document:getPageCount()
    -- 末页 gotoPage 会挪走阅读位置，收尾时放回。
    local restore_xp = rolling and document:getXPointer() or nil
    local cancelled = false
    Paths.ensureCacheRoot()
    local tmp = Paths.cacheDir() .. "/reflow_extract_" .. tostring(os.time()) .. ".txt"
    local file, open_err = io.open(tmp, "wb")
    if not file then
        cb(nil, open_err or _("无法创建临时文件"))
        return { cancel = function() end }
    end
    local previous = ""
    local had_text = false
    local closed = false

    local function discardTmp()
        if not closed then
            closed = true
            file:close()
        end
        os.remove(tmp)
    end

    ---@param err any
    local function fail(err)
        discardTmp()
        if ui.document == document and restore_xp then
            -- 放不回原位置只是阅读位置偏了；抛出去 cb 就不来了，调用方的进度窗会一直挡着阅读页。
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
    -- 进度条按整数百分比走：每批都报会让墨水屏 10 次/秒刷新。
    local reported = -1

    local readPage = rolling and rollingPage or pagingPage

    --- 从第 page 页取到用完一批的时长，没取完排下一批。
    ---@param page integer
    local function step(page)
        if cancelled then
            discardTmp()
            return
        end
        if ui.document ~= document then return fail(_("文档已关闭")) end
        local started = Perf.now()
        while page <= count do
            -- 坏页上 CREngine / MuPDF 会抛错：整次提取作废并告诉用户，不带着半本书继续。
            local ok, chunk = pcall(readPage, document, page, count)
            if not ok or type(chunk) ~= "string" then
                return fail(_("无法提取文字") .. ": " .. tostring(chunk))
            end
            local wrote
            previous, wrote = appendPage(file, previous, chunk)
            if wrote then had_text = true end
            page = page + 1
            if page <= count and Perf.now() - started >= BATCH_MS then
                local percent = math.floor((page - 1) * 100 / count)
                if percent ~= reported then
                    reported = percent
                    on_progress(_("正在提取文字"), page - 1, count)
                end
                -- 词框 / 页字符串这批用完就催一下 GC，别拖到整本取完才收。
                collectgarbage("step", 400)
                return later(function() step(page) end)
            end
        end
        if not closed then
            closed = true
            file:close()
        end
        if not had_text then
            os.remove(tmp)
            return fail(_("文档没有可提取的文字"))
        end
        succeed(tmp)
    end

    later(function() step(1) end)
    return { cancel = function()
        cancelled = true
    end }
end

return Extract
