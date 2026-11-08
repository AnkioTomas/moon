--[[--
盐选短篇首次打开前转成整本 EPUB；旧版划线与图文正文保留原文件。

@module source.zhihu.story
--]]

local Paths = require("utils.paths")
local Text = require("utils.text")
local _ = require("l10n").get("source.zhihu")

local Story = {}

local function headings(html, text)
    local out, numbers = {}, {}
    for _level, title in html:gmatch("<h([1-6])[^>]*>(.-)</h%1>") do
        out[#out + 1] = Text.stripHtml(title)
    end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line:match("^%d%d?%d?$") and tonumber(line) == #numbers + 1 then
            numbers[#numbers + 1] = line
        end
    end
    if #numbers > 1 then
        for _idx, title in ipairs(numbers) do out[#out + 1] = title end
    end
    return out
end

--- 换格式时只带比例，不把 HTML 的 XPointer / 页码套进 EPUB；路径与进度一起提交。
local function register(path, identity)
    local BookDB = require("book.books_db")
    local ProgressDB = require("book.progress_db")
    local book = BookDB.get(identity.source_id, identity.stable_id)
    local previous = book and book.path ~= path and ProgressDB.get(identity.source_id, identity.stable_id)
    local reason
    local ok = require("utils.db").transaction(function()
        local touched, err = require("book.store").touch(path, identity)
        if not touched then reason = err; return false end
        if previous and not ProgressDB.upsert(identity.source_id, identity.stable_id, {
            fraction = previous.fraction, updated_at = require("book.progress").nextRevision(),
        }) then
            reason = _("阅读进度保存失败")
            return false
        end
        return true
    end)
    return ok and path or nil, reason or (not ok and _("无法保存章节文件") or nil)
end

---@param source BookSource
---@param identity BookIdentity
---@param opts table|nil
---@param ops table
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Story.openAsync(source, identity, opts, ops, cb)
    local Chapter = require("source.chapter")
    local notes = require("book.note_db").get(identity.source_id, identity.stable_id, 1)
    if notes and notes.payload ~= "[]" and notes.payload ~= "{}" then
        require("ui.themes.widgets.toast"):new{ text = _("已有划线，保留原始排版") }:show()
        return Chapter.openWithUi(source, identity, identity.book, opts, ops, cb)
    end
    local dest = Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/book.epub"
    if require("libs/libkoreader-lfs").attributes(dest, "mode") == "file" then
        local original = require("utils.fs").read(Paths.chapterPath(identity.stable_id, 1, identity.source_id)) or ""
        local upgraded, upgrade_err = require("source.zhihu.content").upgradeStory(dest, original)
        if not upgraded then return require("source.base").defer(cb, nil, upgrade_err) end
        local path, err = register(dest, identity)
        return require("source.base").defer(cb, path, err)
    end
    local cancelled, active, dialog = false, nil, nil
    local function finish(path, err)
        if dialog then dialog:close(); dialog = nil end
        if not cancelled then cb(path, err) end
    end
    local downloaded = false
    local download = Chapter.openWithUi(source, identity, identity.book, opts, ops, function(path, err)
        downloaded = true
        if cancelled then return end
        active = nil
        if not path then finish(nil, err); return end
        local file, open_err = io.open(path, "rb")
        if not file then finish(nil, open_err); return end
        local html, read_err = file:read("*a")
        file:close()
        if not html then finish(nil, read_err); return end
        if html:find("<!--moon:temp-->", 1, true) then finish(path); return end
        html = Text.htmlBodyFragment(html)
        if html:lower():find("<img%f[%s/>]") then
            require("ui.themes.widgets.toast"):new{ text = _("短篇含图片，保留原始排版") }:show()
            finish(path)
            return
        end
        local text = Text.stripHtml(html)
        if text == "" then finish(nil, _("无文本内容")); return end
        local book = require("book.books_db").get(identity.source_id, identity.stable_id) or identity.book
        dialog = require("ui.themes.widgets.progress_dialog"):new{
            title = book and book.title, text = _("重新排版"), dismissable = false,
        }
        local built = false
        local job = dialog:showWhile(require("convert.text2epub").build, {
            dest = dest, text = text, title = book and book.title, author = book and book.authors,
            identifier = "zhihu-" .. identity.stable_id, reflow = true, headings = headings(html, text),
            tail_html = require("source.zhihu.content").FOOTER,
        }, function(ok, build_err)
            built = true
            if cancelled then return end
            active = nil
            if not ok then finish(nil, build_err); return end
            finish(register(dest, identity))
        end, function(step, done, total)
            if not cancelled and dialog then dialog:update(step, done, total) end
        end)
        if not built then active = job end
    end)
    if not downloaded then active = download end
    return { cancel = function()
        cancelled = true
        if active then active.cancel() end
        if dialog then dialog:close(); dialog = nil end
        os.remove(dest .. ".part")
    end }
end

return Story
