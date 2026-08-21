--[[--
MOBI -> 纯文本 -> EPUB。

CRengine 没有整本导出接口，因此按渲染页提取文本；前 N-1 页使用相邻页
XPointer，最后一页跳到页首后提取当前视口。提取结果交给 text2epub 做章节识别
与物理行合并。转换是有损的，不保留图片、脚注和原样式。

@module koplugin.book.convert.mobi2epub
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Text = require("utils.text")
local _ = require("gettext")

local Mobi2Epub = {}

--- 只消除相邻渲染页完全相同的边界行。
---@param pages string[]
---@param raw string
local function appendPage(pages, raw)
    local page = Text.normalizeNewlines(raw):gsub("^\n+", ""):gsub("\n+$", "")
    if page == "" then
        return
    end
    local previous = pages[#pages]
    if previous then
        local last_line = previous:match("([^\n]+)$")
        local first_line, rest = page:match("^([^\n]+)\n(.*)$")
        if not first_line then
            first_line, rest = page, ""
        end
        if last_line ~= nil and first_line == last_line then
            page = rest
        end
    end
    if page ~= "" then
        pages[#pages + 1] = page
    end
end

--- 按页提取 MOBI 文本后交给 text2epub 打包；可取消。
---@param opts {
---   source: string,
---   dest: string,
---   title: string|nil,
---   author: string|nil,
---   language: string|nil,
---   identifier: string|nil,
---   max_part_chars: number|nil,
---   on_progress: (fun(ev: table))|nil,
--- }
---@param cb fun(ok: boolean|nil, err: any)
---@return { cancel: fun() }
function Mobi2Epub.build(opts, cb)
    opts = opts or {}
    if type(cb) ~= "function" then
        error("mobi2epub.build: cb must be function", 2)
    end

    local source = opts.source
    local cancelled = false
    local finished = false
    local document
    local active_job
    local pages = {}

    local function closeDocument()
        local doc = document
        document = nil
        if doc and type(doc.close) == "function" then
            pcall(doc.close, doc)
        end
    end

    local function emit(ev)
        if not cancelled and type(opts.on_progress) == "function" then
            opts.on_progress(ev)
        end
    end

    local function finish(ok, err)
        if cancelled or finished then
            return
        end
        finished = true
        closeDocument()
        cb(ok, err)
    end

    local job = {}
    function job.cancel()
        if cancelled or finished then
            return
        end
        cancelled = true
        if active_job and type(active_job.cancel) == "function" then
            active_job.cancel()
        end
        active_job = nil
        closeDocument()
    end

    local function buildEpub()
        closeDocument()
        local text = table.concat(pages, "\n")
        if Text.trim(text) == "" then
            finish(nil, _("MOBI 没有可提取的文本"))
            return
        end
        active_job = require("convert.text2epub").build({
            dest = opts.dest,
            text = text,
            source = source,
            title = opts.title,
            author = opts.author,
            language = opts.language,
            identifier = opts.identifier,
            max_part_chars = opts.max_part_chars,
            reflow = true,
            on_progress = opts.on_progress,
        }, function(ok, err)
            active_job = nil
            finish(ok, err)
        end)
    end

    local function extractPage(page, page_count)
        if cancelled then
            return
        end
        local ok, chunk = pcall(function()
            if page < page_count then
                local pos0 = document:getPageXPointer(page)
                local pos1 = document:getPageXPointer(page + 1)
                if type(pos0) ~= "string" or pos0 == ""
                    or type(pos1) ~= "string" or pos1 == ""
                then
                    error("invalid page xpointer")
                end
                return document:getTextFromXPointers(pos0, pos1)
            end

            document:gotoPage(page)
            local Screen = require("device").screen
            local range = document:getTextFromPositions(
                { x = 0, y = 0 },
                { x = Screen:getWidth(), y = Screen:getHeight() },
                true
            )
            return range and range.text
        end)
        if not ok or type(chunk) ~= "string" then
            finish(nil, _("无法提取 MOBI 文本") .. ": " .. tostring(chunk))
            return
        end

        appendPage(pages, chunk)
        emit({ phase = "extract", index = page, total = page_count })
        if page == page_count then
            buildEpub()
        else
            UIManager:nextTick(function()
                extractPage(page + 1, page_count)
            end)
        end
    end

    UIManager:nextTick(function()
        if cancelled then
            return
        end
        if type(source) ~= "string" or not source:lower():match("%.mobi$") then
            finish(nil, _("仅支持 MOBI 文件"))
            return
        end

        local ok, result, open_err = pcall(function()
            local registry = require("document/documentregistry")
            local provider = registry:getProvider(source)
            if not provider or provider.provider ~= "crengine" then
                return nil, _("此 MOBI 无法由 CRengine 打开")
            end
            local doc = registry:openDocument(source, provider)
            if not doc then
                return nil, _("无法读取 MOBI")
            end
            document = doc
            if type(doc.loadDocument) ~= "function" or not doc:loadDocument() then
                return nil, _("无法读取 MOBI")
            end
            if type(doc.render) ~= "function" then
                return nil, _("此 MOBI 无法由 CRengine 打开")
            end
            doc:render()
            local count = math.floor(tonumber(doc:getPageCount()) or 0)
            if count < 1 then
                return nil, _("MOBI 没有可提取的文本")
            end
            return count
        end)
        if not ok then
            finish(nil, _("无法读取 MOBI") .. ": " .. tostring(result))
            return
        end
        if type(result) ~= "number" then
            finish(nil, open_err)
            return
        end
        UIManager:nextTick(function()
            extractPage(1, result)
        end)
    end)

    return job
end

return Mobi2Epub
