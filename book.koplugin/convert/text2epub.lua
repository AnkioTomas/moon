--[[--
纯文本 → EPUB。

负责从文本中提取书名、作者和章节，再复用 html2epub 完成目录与打包。

  local Text2Epub = require("convert.text2epub")
  local job = Text2Epub.build({
      dest = "/path/book.epub",
      source = "/path/book.txt", -- 没给 text / text_file 时读这个；也用于推断书名 / 作者
      text = nil, -- 可省略；已有全文时直接给（主进程慎用，占内存）
      text_file = nil, -- 可省略；提取落盘的临时 txt，子进程读完即删（reflow 走这条）
      title = "书名", -- 可省略
      author = "作者", -- 可省略
  }, function(ok, err) end)
  job.cancel()

@module koplugin.book.convert.text2epub
--]]

local Html2Epub = require("convert.html2epub")
local Text = require("utils.text")
local _ = require("gettext")

local Text2Epub = {}

local trim = Text.trim
local xmlEscape = Text.xmlEscape
local DEFAULT_PART_CHARS = 256 * 1024
local CHINESE_NUMBER_CHARS = { "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "两" }
--- 内嵌目录条目的长度上限（字节，约 40 个汉字）；更长的是正文。
local MAX_TOC_ENTRY_BYTES = 120
--- 连续空章达到这个数就是正文里印的目录页，不是章节（见 dropTocEchoes）。
local MIN_LISTING = 3
local TOC_HEADERS = { ["目录"] = true, ["目錄"] = true, ["content"] = true, ["contents"] = true, ["table of contents"] = true }
local INVALID_VOLUME_SUFFIX = { ["门"] = true, ["队"] = true, ["属"] = true, ["分"] = true, ["件"] = true, ["落"] = true }

---@param value string
---@return boolean
local function isNumberToken(value)
    value = value:gsub("%s+", "")
    if value == "" or value:match("^%d+$") or value:match("^[IVXLCDMivxlcdm]+$") then
        return value ~= ""
    end
    local rest = value
    for _idx, char in ipairs(CHINESE_NUMBER_CHARS) do
        rest = rest:gsub(char, "")
    end
    return rest == ""
end

---@param line string
---@return string|nil
local function chapterTitle(line)
    line = trim(line)
    -- 常见 TXT 章节会用 === 包裹标题；这里只剥离等号，避免吞掉正文。
    line = line:gsub("^=+%s*", ""):gsub("%s*=+$", "")

    if line:match("^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%wIVXLCDMivxlcdm]+[%s:%.%-]?.*$")
        or line:match("^[Ss][Ee][Cc][Tt][Ii][Oo][Nn]%s+[%wIVXLCDMivxlcdm]+[%s:%.%-]?.*$")
        or line:match("^[Pp][Aa][Gg][Ee]%s+%d+[%s:%.%-]?.*$")
    then
        return line
    end

    if line:sub(1, 3) == "第" then
        for _idx, marker in ipairs({ "章", "回", "节", "集", "幕", "卷", "部", "篇" }) do
            local number, suffix = line:match("^第%s*(.-)%s*" .. marker .. "(.*)$")
            if number and isNumberToken(number) then
                -- “第一部门/部队”是正文，不是“第一部”章节。
                if marker ~= "部" or not INVALID_VOLUME_SUFFIX[suffix:sub(1, 3)]
                then
                    return line
                end
            end
        end
    end

    for _index, title in ipairs({
        "序章", "序言", "前言", "楔子", "引子", "尾声", "后记", "番外", "终章", "最终章", "完本感言",
    }) do
        if line == title
            or line:match("^" .. title .. "[%s:%-].+$")
            or line:match("^" .. title .. "：.+$")
        then
            return line
        end
    end
    return nil
end

---@param line string
---@return boolean
local function isChapterTitle(line)
    return chapterTitle(line) ~= nil
end

--- 判断一行是否应当保留为独立段落（列表或对话）。
---@param line string
---@return boolean
local function isHardLine(line)
    return line:match("^%s*[-*•·●○]") ~= nil
        or line:match("^%s*%d+[%.、)]") ~= nil
        or line:match("^%s*[“\"「『]") ~= nil
end

--- 将物理行合并为段落。TXT 的换行常是编辑器软换行，不能逐行生成 p。
---@param lines string[]
---@param reflow boolean|nil
---@return string[][]
local function paragraphsFromLines(lines, reflow)
    local paragraphs = {}
    if not reflow then
        for _idx, raw in ipairs(lines) do
            local line = trim(raw)
            if line ~= "" then
                paragraphs[#paragraphs + 1] = { line }
            end
        end
        return paragraphs
    end
    local current = {}
    --- 结束当前段落：把已累积的行作为一段收下，没有累积行则什么都不做。
    local function flush()
        if #current > 0 then
            paragraphs[#paragraphs + 1] = current
            current = {}
        end
    end
    for _idx, raw in ipairs(lines) do
        local line = Text.rtrim(raw)
        if trim(line) == "" then
            flush()
        elseif isHardLine(line) then
            flush()
            paragraphs[#paragraphs + 1] = { trim(line) }
        else
            if #current > 0 and current[#current]:match("[。！？!?；;]$") then
                flush()
            end
            current[#current + 1] = trim(line)
        end
    end
    flush()
    return paragraphs
end

---@param paragraph string[]
---@return string
local function paragraphText(paragraph)
    -- 一段可能是一整章（英文 PDF 没有空行、句号不断段），逐行 .. 拼接是平方级。
    local out = { paragraph[1] or "" }
    for i = 2, #paragraph do
        local next_line = paragraph[i]
        local left = paragraph[i - 1]:sub(-1)
        local right = next_line:sub(1, 1)
        local ascii_word = left:match("[%w]$") and right:match("^[%w]")
        local after_punctuation = left:match("[,.;:!?%)%]}'\"]$")
            and right:match("^[A-Za-z0-9]")
        if ascii_word or after_punctuation then
            out[#out + 1] = " "
        end
        out[#out + 1] = next_line
    end
    return table.concat(out)
end

--- 在 UTF-8 字符边界前截断，避免把多字节字符拆坏。
---@param text string
---@param start number
---@param limit number
---@return number
local function splitAtUtf8Boundary(text, start, limit)
    local last = math.min(#text, start + limit - 1)
    if last >= #text then
        return #text
    end
    while last > start and string.byte(text, last + 1) >= 0x80 and string.byte(text, last + 1) <= 0xBF do
        last = last - 1
    end
    return math.max(last, start)
end

---@param title string
---@param lines string[]
---@param max_chars number|nil
---@param reflow boolean|nil
---@return string[]
local function chapterParts(title, lines, max_chars, reflow)
    local paragraphs = paragraphsFromLines(lines, reflow)
    local limit = tonumber(max_chars) or DEFAULT_PART_CHARS
    if limit < 1 then
        limit = DEFAULT_PART_CHARS
    end
    local parts, body = {}, {}
    local body_chars = 0
    --- 把已累积的段落封成一个分片的 XHTML 片段；首个分片额外带 h1 标题。
    local function flush()
        if #body == 0 then
            return
        end
        local out = {}
        if #parts == 0 then
            out[#out + 1] = "<h1>" .. xmlEscape(title) .. "</h1>"
        end
        for _idx, p in ipairs(body) do
            out[#out + 1] = "<p>" .. xmlEscape(p) .. "</p>"
        end
        parts[#parts + 1] = table.concat(out, "\n")
        body, body_chars = {}, 0
    end
    for _idx, paragraph in ipairs(paragraphs) do
        local text = paragraphText(paragraph)
        local start = 1
        while #text - start + 1 > limit do
            if body_chars > 0 then
                flush()
            end
            local last = splitAtUtf8Boundary(text, start, limit)
            body[#body + 1] = text:sub(start, last)
            body_chars = last - start + 1
            flush()
            start = last + 1
        end
        text = text:sub(start)
        if body_chars > 0 and body_chars + #text > limit then
            flush()
        end
        body[#body + 1] = text
        body_chars = body_chars + #text
    end
    flush()
    if #parts == 0 then
        parts[1] = "<h1>" .. xmlEscape(title) .. "</h1>"
    end
    return parts
end

---@param source string|nil
---@return string|nil, string|nil
local function metadataFromPath(source)
    local name = type(source) == "string" and source:match("([^/\\]+)$") or nil
    if not name then
        return nil
    end
    name = name:gsub("%.[^%.]+$", "")
    local title, author = name:match("^《(.-)》.-作者%s*：(.+)$")
    if not title then
        title, author = name:match("^《(.-)》.-作者%s*:(.+)$")
    end
    if title and trim(title) ~= "" and trim(author) ~= "" then
        return trim(title), trim(author)
    end
    return trim(name) ~= "" and trim(name) or nil
end

---@param lines string[]
---@return boolean
local function blank(lines)
    for _idx, line in ipairs(lines) do
        if trim(line) ~= "" then return false end
    end
    return true
end

--- 内嵌目录把每个标题都列一遍，会切出一串空章：空章后面还有同名章节就丢掉，留带正文的那个。
--- 剩下连续 MIN_LISTING 个以上的空章也是目录页（条目与正文标题写法对不上，如合集每卷卷首、书末的
--- 「第一章　源家次子 The Second…」对正文的「第一章」）：标题还原成上一章末尾的段落，不丢字。
--- 不到这个数的是卷名这类结构标题，照旧成章。
---@param sections { title: string, lines: string[] }[]
---@return { title: string, lines: string[] }[]
local function dropTocEchoes(sections)
    local remaining = {}
    for _idx, section in ipairs(sections) do
        remaining[section.title] = (remaining[section.title] or 0) + 1
    end
    local kept, run = {}, {}
    local function flushRun()
        if #run >= MIN_LISTING then
            if #kept == 0 then kept[1] = { title = _("前言"), lines = {} } end
            local lines = kept[#kept].lines
            for _idx, section in ipairs(run) do
                lines[#lines + 1] = ""
                lines[#lines + 1] = section.title
            end
        else
            for _idx, section in ipairs(run) do kept[#kept + 1] = section end
        end
        run = {}
    end
    for _idx, section in ipairs(sections) do
        remaining[section.title] = remaining[section.title] - 1
        if not blank(section.lines) then
            flushRun()
            kept[#kept + 1] = section
        elseif remaining[section.title] == 0 then
            run[#run + 1] = section
        end
    end
    flushRun()
    return kept
end

--- 正文里的内嵌目录：表头（目录 / Contents）之后连续的短行，遇到重复的标题（正文开始了）为止。
--- 只有这样收尾的才算数：遇到长行或到文末都没重复，说明条目对不上正文（如带页码），
--- 收到的多半混进了正文短句，整批丢掉，否则全书每出现一次这句就切一章。
--- 不读 NCX 的文档（如 CREngine 打开的 MOBI 6）只有这一份目录。
---@param lines string[]
---@param known table<string, boolean> 收进来的标题（就地加）
local function collectInlineToc(lines, known)
    local entries
    for _idx, raw in ipairs(lines) do
        local line = trim(raw)
        if TOC_HEADERS[line:lower()] then
            entries = {}
        elseif entries and line ~= "" then
            if entries[line] then
                for entry in pairs(entries) do known[entry] = true end
                entries = nil
            elseif #line > MAX_TOC_ENTRY_BYTES then
                entries = nil
            else
                entries[line] = true
            end
        end
    end
end

---解析纯文本。显式 title/author 优先，其次读取“书名/作者”元数据；
---没有书名元数据时使用文件名，最后才使用首个非空行。
---章节标题：与目录标题（opts.headings 原文档自带目录，加上正文里的内嵌目录）完全相同的整行，
---或常见章节写法（chapterTitle）。
---@param text string
---@param opts table|nil
---@param progress fun(done: integer, total: integer)|nil 每排完一节
---@return { title: string, author: string|nil, chapters: { title: string, html: string, toc: boolean }[] }
function Text2Epub.parse(text, opts, progress)
    opts = opts or {}
    text = Text.stripBom(Text.normalizeNewlines(text))
    local known = {}
    for _idx, heading in ipairs(opts.headings or {}) do
        known[trim(heading)] = true
    end
    ---@param line string 已 trim 的非空行
    ---@return string|nil
    local function headingOf(line)
        return known[line] and line or chapterTitle(line)
    end

    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    -- 行表已立，整串可以放掉；后面只用 lines。
    text = nil
    collectInlineToc(lines, known)

    local title = trim(opts.title)
    local author = trim(opts.author)
    local content = {}
    local metadata_open = true

    for index, raw in ipairs(lines) do
        local line = trim(raw)
        if line ~= "" and headingOf(line) then
            metadata_open = false
        end
        local metadata_title
        local metadata_author
        if metadata_open and index <= 20 then
            metadata_title = line:match("^书名%s*:%s*(.+)$")
                or line:match("^书名%s*：%s*(.+)$")
                or line:match("^[Tt][Ii][Tt][Ll][Ee]%s*:%s*(.+)$")
            metadata_author = line:match("^作者%s*:%s*(.+)$")
                or line:match("^作者%s*：%s*(.+)$")
                or line:match("^[Aa][Uu][Tt][Hh][Oo][Rr]%s*:%s*(.+)$")
        end
        if metadata_title then
            if title == "" then
                title = trim(metadata_title)
            end
        elseif metadata_author then
            if author == "" then
                author = trim(metadata_author)
            end
        else
            content[#content + 1] = raw
        end
    end

    local path_title, path_author = metadataFromPath(opts.source)
    if title == "" then
        title = path_title or ""
    end
    if author == "" then
        author = path_author or ""
    end
    if title == "" then
        for i, raw in ipairs(content) do
            local line = trim(raw)
            if line ~= "" then
                title = line
                table.remove(content, i)
                break
            end
        end
    end
    if title == "" then
        title = _("未命名")
    end
    for index, raw in ipairs(content) do
        local line = trim(raw)
        if line ~= "" then
            if line == title and not headingOf(line) then
                table.remove(content, index)
            end
            break
        end
    end

    local sections = {}
    local current
    --- 开启一个新章节，后续正文行都归入它。
    ---@param section_title string 章节标题
    local function startSection(section_title)
        current = { title = section_title, lines = {} }
        sections[#sections + 1] = current
    end

    for _index, raw in ipairs(content) do
        local line = trim(raw)
        local heading = line ~= "" and headingOf(line)
        if TOC_HEADERS[line:lower()] then
            -- 内嵌目录的表头：条目已由 dropTocEchoes 去掉，单留表头没有意义
        elseif heading and current and heading == current.title then
            -- 与本章标题相同的行是 PDF 每页的页眉，不另起一章
        elseif heading then
            startSection(heading)
        elseif current then
            current.lines[#current.lines + 1] = raw
        elseif line ~= "" then
            startSection(_("前言"))
            current.lines[#current.lines + 1] = raw
        end
    end

    -- content / lines 已拆进 sections，先断引用再切 HTML，压峰值。
    content = nil
    lines = nil

    sections = dropTocEchoes(sections)
    if #sections == 0 then
        startSection(title)
    elseif #sections == 1 and sections[1].title == _("前言") then
        sections[1].title = title
    end

    local chapters = {}
    local max_part_chars = opts.max_part_chars or DEFAULT_PART_CHARS
    for index, section in ipairs(sections) do
        local parts = chapterParts(section.title, section.lines, max_part_chars, opts.reflow == true)
        section.lines = nil
        for part_index, html in ipairs(parts) do
            chapters[#chapters + 1] = {
                title = section.title,
                html = html,
                toc = part_index == 1,
            }
        end
        if progress then progress(index, #sections) end
    end

    return {
        title = title,
        author = author ~= "" and author or nil,
        chapters = chapters,
    }
end

--- 读取文本文件并转成 UTF-8：非 UTF-8 的按 BOM 声明（UTF-16）或 GBK / GB18030 转码；空文件或转不出文字视为失败。
---@param source string
---@return string|nil text, string|nil err
function Text2Epub.read(source)
    local file = io.open(source, "rb")
    if not file then
        return nil, _("无法读取文本文件")
    end
    local text = file:read("*a")
    file:close()
    if type(text) ~= "string" or trim(text) == "" then
        return nil, _("无文本内容")
    end
    if Text.isValidUtf8(text) then
        return text
    end
    local Charset = require("utils.charset")
    local converted = Charset.toUtf8(text, not Charset.detect(text) and "charset=gb18030" or nil)
    if not (converted and Text.isValidUtf8(converted) and trim(converted) ~= "") then
        return nil, _("无法识别文本编码")
    end
    return converted
end

--- 子进程里跑 worker(report)：整本书在 UI 线程上要跑几十秒。report(text, done, total) 按整数百分比节流
--- （管道有容量上限），父进程转给 on_progress。worker 返回 { err } 表示失败，否则把结果表交给 cb。
---@param name string
---@param worker fun(report: fun(text: string, done: integer, total: integer)): table
---@param cb fun(result: table|nil, err: any)
---@param on_progress fun(text: string, done: integer, total: integer)|nil
---@return { cancel: fun() }
local function runJob(name, worker, cb, on_progress)
    local job = require("workers.job").run(function(progress)
        local last_text, last_percent
        return worker(function(text, done, total)
            local percent = math.floor(done * 100 / total)
            if text == last_text and percent == last_percent then return end
            last_text, last_percent = text, percent
            progress({ text = text, done = done, total = total })
        end)
    end, {
        name = name,
        kind = "medium",
        on_progress = on_progress and function(value) on_progress(value.text, value.done, value.total) end,
        on_done = function(result)
            if result.err then cb(nil, result.err) else cb(result) end
        end,
        on_failed = function(err) cb(nil, err) end,
    })
    return { cancel = function() job:cancel() end }
end

--- opts.text 优先；否则 opts.text_file（提取临时文件）；再否则读 opts.source。
---@param opts table
---@return string|nil text, string|nil err
local function load(opts)
    if opts.text then return opts.text end
    if opts.text_file then return Text2Epub.read(opts.text_file) end
    return Text2Epub.read(opts.source)
end

--- 异步构建 EPUB，读文件、解析、打包都在子进程里。
--- opts.text 是全文；opts.text_file 是提取落盘的临时文件；都没给就读 opts.source。
--- opts.source 也用于从文件名推断书名 / 作者（与 text_file 可同时存在）。
---@param opts {
---   dest: string,
---   text: string|nil,
---   text_file: string|nil,
---   source: string|nil,
---   title: string|nil,
---   author: string|nil,
---   language: string|nil,
---   identifier: string|nil,
---   reflow: boolean|nil,
---   max_part_chars: number|nil,
---   headings: string[]|nil,
--- }
---@param cb fun(ok: boolean|nil, err: any)
---@param on_progress fun(text: string, done: integer, total: integer)|nil
---@return { cancel: fun() }
function Text2Epub.build(opts, cb, on_progress)
    return runJob("epub.text", function(report)
        local text, err = load(opts)
        -- 子进程里断掉 opts 上的全文引用，parse 拆行后即可回收整串。
        opts.text = nil
        if not text then return { err = err } end
        local book = Text2Epub.parse(text, opts, function(done, total) report(_("正在识别章节"), done, total) end)
        text = nil
        local ok, write_err = Html2Epub.write({
            dest = opts.dest,
            title = book.title,
            author = book.author,
            language = opts.language,
            identifier = opts.identifier,
            chapters = book.chapters,
        }, function(done, total) report(_("正在写入"), done, total) end)
        return { err = not ok and (write_err or _("写入 epub 失败")) or nil }
    end, function(result, err) cb(result and true, err) end, on_progress)
end

Text2Epub.chapterTitle = chapterTitle
Text2Epub._isChapterTitle = isChapterTitle

return Text2Epub
