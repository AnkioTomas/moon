--[[--
纯文本 → EPUB。

负责从文本中提取书名、作者和章节，再复用 html2epub 完成目录与打包。

  local Text2Epub = require("convert.text2epub")
  local job = Text2Epub.build({
      dest = "/path/book.epub",
      source = "/path/book.txt",
      title = "书名", -- 可省略
      author = "作者", -- 可省略
  }, function(ok, err) end)
  job.cancel()

@module koplugin.book.convert.text2epub
--]]

local UIManager = require("ui/uimanager")
local Html2Epub = require("convert.html2epub")
local Text = require("utils.text")
local _ = require("gettext")

local Text2Epub = {}

local trim = Text.trim
local xmlEscape = Text.xmlEscape

---@param line string
---@return boolean
local function isChapterTitle(line)
    if line:match("^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%dIVXLCDMivxlcdm]+[%s:%.%-]?.*$") then
        return true
    end

    for _index, marker in ipairs({ "章", "回", "节", "卷", "部", "篇" }) do
        if line:match("^第%s*.-" .. marker .. "%s*.*$") then
            return true
        end
    end

    for _index, title in ipairs({ "序章", "序言", "前言", "楔子", "引子", "尾声", "后记", "番外" }) do
        if line == title
            or line:match("^" .. title .. "[%s:%-].+$")
            or line:match("^" .. title .. "：.+$")
        then
            return true
        end
    end
    return false
end

---@param title string
---@param lines string[]
---@return string
local function chapterHtml(title, lines)
    local out = { "<h1>" .. xmlEscape(title) .. "</h1>" }
    for _index, line in ipairs(lines) do
        line = trim(line)
        if line ~= "" then
            out[#out + 1] = "<p>" .. xmlEscape(line) .. "</p>"
        end
    end
    return table.concat(out, "\n")
end

---@param source string|nil
---@return string|nil
local function titleFromPath(source)
    local name = type(source) == "string" and source:match("([^/\\]+)$") or nil
    if not name then
        return nil
    end
    name = name:gsub("%.[^%.]+$", "")
    return trim(name) ~= "" and trim(name) or nil
end

---解析纯文本。显式 title/author 优先，其次读取“书名/作者”元数据；
---没有书名元数据时使用文件名，最后才使用首个非空行。
---@param text string
---@param opts table|nil
---@return { title: string, author: string|nil, chapters: { title: string, html: string }[] }
function Text2Epub.parse(text, opts)
    opts = opts or {}
    text = Text.stripBom(Text.normalizeNewlines(text))

    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end

    local title = trim(opts.title)
    local author = trim(opts.author)
    local content = {}
    local metadata_open = true

    for index, raw in ipairs(lines) do
        local line = trim(raw)
        if line ~= "" and isChapterTitle(line) then
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

    if title == "" then
        title = titleFromPath(opts.source) or ""
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
            if line == title and not isChapterTitle(line) then
                table.remove(content, index)
            end
            break
        end
    end

    local sections = {}
    local current
    local function startSection(section_title)
        current = { title = section_title, lines = {} }
        sections[#sections + 1] = current
    end

    for _index, raw in ipairs(content) do
        local line = trim(raw)
        if line ~= "" and isChapterTitle(line) then
            startSection(line)
        elseif current then
            current.lines[#current.lines + 1] = raw
        elseif line ~= "" then
            startSection(_("前言"))
            current.lines[#current.lines + 1] = raw
        end
    end

    if #sections == 0 then
        startSection(title)
    elseif #sections == 1 and sections[1].title == _("前言") then
        sections[1].title = title
    end

    local chapters = {}
    for _index, section in ipairs(sections) do
        chapters[#chapters + 1] = {
            title = section.title,
            html = chapterHtml(section.title, section.lines),
        }
    end

    return {
        title = title,
        author = author ~= "" and author or nil,
        chapters = chapters,
    }
end

---@param source string
---@return string|nil, string|nil
local function readText(source)
    local file, err = io.open(source, "rb")
    if not file then
        return nil, err
    end
    local text = file:read("*a")
    file:close()
    return text
end

---异步构建 EPUB。opts.text 与 opts.source 至少提供一个。
---@param opts {
---   dest: string,
---   text: string|nil,
---   source: string|nil,
---   title: string|nil,
---   author: string|nil,
---   language: string|nil,
---   identifier: string|nil,
---   on_progress: (fun(ev: table))|nil,
--- }
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }
function Text2Epub.build(opts, cb)
    opts = opts or {}
    if type(cb) ~= "function" then
        error("text2epub.build: cb must be function", 2)
    end

    local text = opts.text
    if type(text) ~= "string" and type(opts.source) == "string" then
        local err
        text, err = readText(opts.source)
        if not text then
            UIManager:nextTick(function()
                cb(nil, err or _("无法读取文本文件"))
            end)
            return { cancel = function() end }
        end
    end
    if type(text) ~= "string" or trim(text) == "" then
        UIManager:nextTick(function()
            cb(nil, _("无文本内容"))
        end)
        return { cancel = function() end }
    end

    local book = Text2Epub.parse(text, opts)
    return Html2Epub.build({
        dest = opts.dest,
        title = book.title,
        author = book.author,
        language = opts.language,
        identifier = opts.identifier,
        chapters = book.chapters,
        on_progress = opts.on_progress,
    }, cb)
end

Text2Epub._isChapterTitle = isChapterTitle
Text2Epub._chapterHtml = chapterHtml

return Text2Epub
