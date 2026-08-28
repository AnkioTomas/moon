--[[--
本地 TXT/MOBI 重新排版：章节分析预览与 EPUB 转换替换。

@module koplugin.book.reflow
--]]

require("l10n").apply()

local Text2Epub = require("convert.text2epub")
local Text = require("utils.text")
local T = require("ffi/util").template
local _ = require("gettext")

local Reflow = {}

---@type table<string, { text: string|nil, parsed: table }>
local preview_cache = {}

---@param identity BookIdentity|nil
---@return boolean
function Reflow.canReflow(identity)
    if not identity or identity.source_id ~= "local" then
        return false
    end
    local source = identity.source
    if not source or type(source.replaceBook) ~= "function" then
        return false
    end
    local path = identity.stable_id
    if type(path) ~= "string" then
        return false
    end
    local lower = path:lower()
    return lower:match("%.txt$") ~= nil or lower:match("%.mobi$") ~= nil
end

---@param path string
---@return "txt"|"mobi"|nil
local function fileKind(path)
    local lower = path:lower()
    if lower:match("%.txt$") then
        return "txt"
    end
    if lower:match("%.mobi$") then
        return "mobi"
    end
    return nil
end

---@param parsed { chapters: { title: string, toc: boolean|nil }[] }
---@return string[]
local function tocTitles(parsed)
    local titles = {}
    for _, chapter in ipairs(parsed.chapters or {}) do
        if chapter.toc ~= false then
            titles[#titles + 1] = chapter.title ~= "" and chapter.title
                or ("#" .. (#titles + 1))
        end
    end
    return titles
end

---@param path string
---@param identity BookIdentity
---@return table
local function buildOpts(path, identity)
    local book = identity.book or {}
    local Paths = require("utils.paths")
    return {
        source = path,
        title = book.title,
        author = book.authors,
        identifier = "moon-reflow-" .. Paths.slugFor(path),
        reflow = true,
    }
end

---@param path string
---@param parse_opts table
---@param text string
---@return table, string[]
local function cacheParsed(path, parse_opts, text)
    local parsed = Text2Epub.parse(text, parse_opts)
    preview_cache[path] = { text = text, parsed = parsed }
    return parsed, tocTitles(parsed)
end

--- 分析章节结构，供预览目录使用。
---@param identity BookIdentity
---@param cb fun(titles: string[]|nil, err: string|nil)
---@return { cancel: fun() }
function Reflow.analyzeAsync(identity, cb)
    local path = identity.stable_id
    local kind = fileKind(path)
    if not kind then
        require("ui/uimanager"):nextTick(function()
            cb(nil, _("无效路径"))
        end)
        return { cancel = function() end }
    end

    local parse_opts = buildOpts(path, identity)
    if kind == "txt" then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function()
            local file, err = io.open(path, "rb")
            if not file then
                cb(nil, err or _("无法读取文本文件"))
                return
            end
            local text = file:read("*a")
            file:close()
            if type(text) ~= "string" or Text.trim(text) == "" then
                cb(nil, _("无文本内容"))
                return
            end
            if not Text.isValidUtf8(text) then
                cb(nil, _("仅支持 UTF-8 编码的文本"))
                return
            end
            local _, titles = cacheParsed(path, parse_opts, text)
            cb(titles)
        end)
        return { cancel = function() end }
    end

    return require("convert.mobi2epub").extract({
        source = path,
        on_progress = parse_opts.on_progress,
    }, function(text, err)
        if not text then
            cb(nil, err)
            return
        end
        local _, titles = cacheParsed(path, parse_opts, text)
        cb(titles)
    end)
end

--- 转换并替换原书，完成后回调新路径。
---@param identity BookIdentity
---@param cb fun(new_path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Reflow.applyAsync(identity, cb)
    local path = identity.stable_id
    local kind = fileKind(path)
    if not kind then
        require("ui/uimanager"):nextTick(function()
            cb(nil, _("无效路径"))
        end)
        return { cancel = function() end }
    end

    local source = identity.source
    if not source or type(source.replaceBook) ~= "function" then
        require("ui/uimanager"):nextTick(function()
            cb(nil, _("当前书籍不支持排版"))
        end)
        return { cancel = function() end }
    end

    local parse_opts = buildOpts(path, identity)
    local target = path:gsub("%.[^./]+$", ".epub")
    local dest = target .. ".moon-reflow"
    local cached = preview_cache[path]

    --- 转换收尾：成功则用产物替换原书并登记新路径，失败清掉临时文件。
    --- 任何一步失败都保证 dest 与 dest.part 不残留，且不改动原书。
    ---@param ok boolean 转换是否成功
    ---@param err string|nil 转换失败原因
    local function finishReplace(ok, err)
        preview_cache[path] = nil
        if not ok then
            pcall(os.remove, dest)
            pcall(os.remove, dest .. ".part")
            cb(nil, err or _("排版失败"))
            return
        end
        local replaced, replace_err = source:replaceBook(dest, path)
        if not replaced then
            pcall(os.remove, dest)
            pcall(os.remove, dest .. ".part")
            cb(nil, replace_err or _("替换原书失败"))
            return
        end
        local touch_identity = {}
        for key, value in pairs(identity) do
            touch_identity[key] = value
        end
        touch_identity.stable_id = replaced
        touch_identity.path = replaced
        require("book.store").touchAsync(replaced, touch_identity)
        cb(replaced)
    end

    if kind == "txt" then
        local text = cached and cached.text
        local build_opts = {
            dest = dest,
            source = path,
            title = parse_opts.title,
            author = parse_opts.author,
            identifier = parse_opts.identifier,
            reflow = true,
        }
        if text then
            build_opts.text = text
        end
        return Text2Epub.build(build_opts, finishReplace)
    end

    if cached and cached.text then
        return Text2Epub.build({
            dest = dest,
            text = cached.text,
            source = path,
            title = parse_opts.title,
            author = parse_opts.author,
            identifier = parse_opts.identifier,
            reflow = true,
        }, finishReplace)
    end

    return require("convert.mobi2epub").build({
        dest = dest,
        source = path,
        title = parse_opts.title,
        author = parse_opts.author,
        identifier = parse_opts.identifier,
    }, finishReplace)
end

--- 阅读页入口：先预览目录，确认后再转换替换并重新打开。
---@param ui table|nil
---@param identity BookIdentity
---@return void
function Reflow.startFromReader(ui, identity)
    if not Reflow.canReflow(identity) then
        return
    end
    local path = identity.stable_id
    local kind = fileKind(path)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local Popup = require("ui.components.popup")
    local holder = { analyze_job = nil, apply_job = nil, dialog = nil }

    --- 关掉当前进度提示框（幂等，没有框时什么都不做）。
    local function closeDialog()
        if holder.dialog then
            UIManager:close(holder.dialog)
            holder.dialog = nil
        end
    end

    --- 取消进行中的分析/转换任务并丢弃该书的预览缓存。
    local function cancelJobs()
        if holder.analyze_job and holder.analyze_job.cancel then
            holder.analyze_job.cancel()
        end
        if holder.apply_job and holder.apply_job.cancel then
            holder.apply_job.cancel()
        end
        holder.analyze_job, holder.apply_job = nil, nil
        preview_cache[path] = nil
    end

    --- 弹出章节预览列表；确认后才真正转换并用新书重开阅读器。
    --- 列表项一律禁用（只读预览）；未识别到章节则只提示不弹表。
    ---@param titles string[]|nil 识别出的章节标题
    local function showPreview(titles)
        if not titles or #titles == 0 then
            UIManager:show(InfoMessage:new{ text = _("未识别到章节") })
            return
        end
        local items = {}
        for _, title in ipairs(titles) do
            items[#items + 1] = { text = title, enabled = false, dim = true }
        end
        local preview_menu
        --- 关掉预览列表（幂等）。
        local function closePreview()
            if preview_menu then
                UIManager:close(preview_menu)
                preview_menu = nil
            end
        end
        preview_menu = Popup.list{
            title = _("排版预览"),
            subtitle = T(_("识别到 %1 章；确认后将替换原书"), #titles),
            items = items,
            bottom_tabs = {
                tabs = {
                    { id = "cancel", text = _("取消"), icon = "close" },
                    { id = "apply", text = _("确认优化"), icon = "check" },
                },
                active = "cancel",
                on_tab = function(tab_id)
                    if tab_id == "cancel" then
                        closePreview()
                        preview_cache[path] = nil
                        return
                    end
                    closePreview()
                    holder.dialog = InfoMessage:new{ text = _("正在优化排版…") }
                    UIManager:show(holder.dialog)
                    holder.apply_job = Reflow.applyAsync(identity, function(new_path, err)
                        holder.apply_job = nil
                        closeDialog()
                        if not new_path then
                            UIManager:show(InfoMessage:new{ text = err or _("排版失败") })
                            return
                        end
                        require("apps/reader/readerui"):showReader(new_path)
                    end)
                end,
            },
            close_callback = function()
                preview_cache[path] = nil
            end,
        }
    end

    --- 显示进度提示并异步识别章节，成功后转入预览。
    local function runAnalyze()
        closeDialog()
        holder.dialog = InfoMessage:new{ text = _("正在分析章节…") }
        UIManager:show(holder.dialog)
        holder.analyze_job = Reflow.analyzeAsync(identity, function(titles, err)
            holder.analyze_job = nil
            closeDialog()
            if not titles then
                UIManager:show(InfoMessage:new{ text = err or _("排版失败") })
                return
            end
            showPreview(titles)
        end)
    end

    if kind == "mobi" then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("转换后的 EPUB 会替换原书；只保留文字并重新识别章节，图片、脚注和原排版会丢失。继续？"),
            ok_text = _("继续"),
            ok_callback = runAnalyze,
            cancel_callback = function()
                cancelJobs()
            end,
        })
        return
    end
    runAnalyze()
end

Reflow._tocTitles = tocTitles

return Reflow
