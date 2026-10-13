--[[--
本地 TXT/MOBI 重新排版：章节分析预览与 EPUB 转换替换。

分析得到的全文由预览持有，确认后原样交给转换，不重复读盘 / 提取。

@module koplugin.book.features.reflow
--]]

require("l10n").apply()

local Text2Epub = require("convert.text2epub")
local T = require("ffi/util").template
local _ = require("gettext")

local Reflow = {}

---@class ReflowPreview
---@field text string 全文
---@field titles string[] 识别出的目录标题

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

--- 排版读写的是本地物理文件（books.path）：普通本地书即 stable_id，WebDAV 书是下载到本地的那份。
---@param identity BookIdentity
---@return string|nil
local function bookFile(identity)
    return identity.book and identity.book.path
end

---@param identity BookIdentity|nil
---@return boolean
function Reflow.canReflow(identity)
    if not identity or identity.source_id ~= "local" then
        return false
    end
    local path = bookFile(identity)
    return type(path) == "string" and fileKind(path) ~= nil
end

---@param parsed { chapters: { title: string, toc: boolean|nil }[] }
---@return string[]
local function tocTitles(parsed)
    local titles = {}
    for _idx, chapter in ipairs(parsed.chapters) do
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
    local book = identity.book
    return {
        source = path,
        title = book.title,
        author = book.authors,
        identifier = "moon-reflow-" .. require("utils.paths").slugFor(path),
        reflow = true,
    }
end

--- 读出全文并识别章节，供预览目录使用。
---@param identity BookIdentity 已经 `canReflow`
---@param cb fun(preview: ReflowPreview|nil, err: string|nil)
---@return { cancel: fun() }
function Reflow.analyzeAsync(identity, cb)
    local path = bookFile(identity)
    ---@cast path string
    local function done(text, err)
        if not text then
            cb(nil, err)
            return
        end
        local parsed = Text2Epub.parse(text, buildOpts(path, identity))
        cb({ text = text, titles = tocTitles(parsed) })
    end
    if fileKind(path) == "mobi" then
        return require("features.reflow.mobi").extract(path, done)
    end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("reflow read", function()
        done(Text2Epub.read(path))
    end))
    return { cancel = function() end }
end

--- 把预览得到的全文转成 EPUB 并替换原书，完成后回调新路径。
--- 任何一步失败都保证 dest 与 dest.part 不残留，且不改动原书。
---@param identity BookIdentity 已经 `canReflow`
---@param text string `analyzeAsync` 给出的全文
---@param cb fun(new_path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Reflow.applyAsync(identity, text, cb)
    local path = bookFile(identity)
    ---@cast path string
    local dest = path:gsub("%.[^./]+$", ".epub") .. ".moon-reflow"
    local active

    local function fail(err)
        os.remove(dest)
        os.remove(dest .. ".part")
        cb(nil, err)
    end

    local opts = buildOpts(path, identity)
    opts.dest = dest
    opts.text = text
    active = Text2Epub.build(opts, function(ok, err)
        if not ok then return fail(err or _("排版失败")) end
        active = identity.source:replaceBookAsync(dest, identity.stable_id, function(new_path, replace_err)
            if not new_path then return fail(replace_err or _("替换原书失败")) end
            cb(new_path)
        end)
    end)
    return { cancel = function()
        if active and active.cancel then active.cancel() end
    end }
end

--- 阅读页入口：先预览目录，确认后再转换替换并重新打开。
---@param identity BookIdentity 已经 `canReflow`（快捷面板先判 available 再 run）
function Reflow.startFromReader(identity)
    local Confirm = require("ui.themes.widgets.confirm")
    local List = require("ui.themes.widgets.list")
    local Toast = require("ui.themes.widgets.toast")

    --- 转换替换并用新书重开阅读器。
    ---@param text string 预览持有的全文
    local function apply(text)
        local loading = Toast:new{ text = _("正在优化排版…") }
        loading:show()
        Reflow.applyAsync(identity, text, function(new_path, err)
            loading:close()
            if not new_path then
                Toast:new{ text = err or _("排版失败") }:show()
                return
            end
            require("apps/reader/readerui"):showReader(new_path)
        end)
    end

    --- 弹出章节预览列表：首行确认优化，其余章节只读；右上角关闭即放弃。
    --- 未识别到章节则只提示不弹表。
    ---@param preview ReflowPreview
    local function showPreview(preview)
        if #preview.titles == 0 then
            Toast:new{ text = _("未识别到章节") }:show()
            return
        end
        local list
        local items = { { text = _("确认优化"), icon = "check", keep_open = true, callback = function()
            list:close()
            apply(preview.text)
        end } }
        for _idx, title in ipairs(preview.titles) do
            items[#items + 1] = { text = title, enabled = false }
        end
        list = List:new{
            title = _("排版预览"),
            subtitle = T(_("识别到 %1 章；确认后将替换原书"), #preview.titles),
            items = items,
        }
        list:show()
    end

    --- 显示进度提示并异步识别章节，成功后转入预览。
    local function runAnalyze()
        local loading = Toast:new{ text = _("正在分析章节…") }
        loading:show()
        Reflow.analyzeAsync(identity, function(preview, err)
            loading:close()
            if not preview then
                Toast:new{ text = err or _("排版失败") }:show()
                return
            end
            showPreview(preview)
        end)
    end

    if fileKind(bookFile(identity)) == "mobi" then
        Confirm:new{
            text = _("转换后的 EPUB 会替换原书；只保留文字并重新识别章节，图片、脚注和原排版会丢失。继续？"),
            ok_text = _("继续"),
            ok_callback = runAnalyze,
        }:show()
        return
    end
    runAnalyze()
end

Reflow._tocTitles = tocTitles

return Reflow
