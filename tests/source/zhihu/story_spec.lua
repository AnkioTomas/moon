--[[--
短篇 EPUB：源内重排、内部目录、旧进度迁移和原始注解保护。

@module tests.source.zhihu.story_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")
Themed.install()
local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块") end
local JSON = require("support.json_stub")
package.loaded.json = JSON
local db_path = Config.dir() .. "/zhihu_story_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
local Paths = require("utils.paths")
package.loaded["utils.paths"] = setmetatable({ dbPath = function() return db_path end }, { __index = Paths })
local DB = require("utils.db")
local BookDB = require("book.books_db")
local ProgressDB = require("book.progress_db")
local NoteDB = require("book.note_db")
local Store = require("book.store")
local identity = { source_id = "zhihu", stable_id = "910000001/910000002" }
local original = Paths.chapterPath(identity.stable_id, 1, identity.source_id)
local dest = Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/book.epub"
Assert.is_true(Paths.ensureDir(original:match("(.+)/[^/]+$")))
Assert.is_true(BookDB.upsertLocal({
    source_id = identity.source_id, stable_id = identity.stable_id, title = "短篇样例", authors = "作者",
}))
local RealConverter = require("convert.text2epub")
local conversions, downloads = {}, 0
package.loaded["convert.text2epub"] = {
    build = function(opts, cb, progress)
        local item = { opts = opts, cb = cb, progress = progress }
        conversions[#conversions + 1] = item
        return { cancel = function() item.cancelled = true end }
    end,
}
package.loaded["source.chapter"] = {
    openWithUi = function(_source, id, _book, _opts, _ops, cb)
        downloads = downloads + 1
        Assert.is_true(Store.touch(original, id, { chapter_idx = 1 }))
        cb(original)
        return { cancel = function() error("已同步完成的下载不能覆盖转换任务") end }
    end,
}
local Story = require("source.zhihu.story")
local Content = require("source.zhihu.content")
local upgrade_story = Content.upgradeStory
Content.upgradeStory = function(path)
    Assert.eq(path, dest)
    return true
end
local result, err, calls = nil, nil, 0
local function done(path, reason) result, err, calls = path, reason, calls + 1 end
local function reset(html)
    os.remove(dest)
    os.remove(dest .. ".part")
    NoteDB.removeIdentity(identity.source_id, identity.stable_id)
    ProgressDB.removeIdentity(identity.source_id, identity.stable_id)
    BookDB.touchPath(identity.source_id, identity.stable_id, original)
    local file = assert(io.open(original, "wb"))
    assert(file:write(html))
    file:close()
    result, err = nil, nil
end
local html = "<html><head><title>短篇样例</title></head><body>"
    .. "<h2>序幕</h2><p>开场文字。</p><p>01</p><p>第一段。</p><p>02</p><p>第二段。</p></body></html>"
reset(html)
Assert.is_true(ProgressDB.upsert(identity.source_id, identity.stable_id, {
    fraction = .4, chapter_idx = 1, chapter_fraction = .4, locator = "html-pointer", page = 5, total_pages = 12,
}))
Story.openAsync({}, identity, nil, {}, done)
local conversion = conversions[#conversions]
local parsed = RealConverter.parse(conversion.opts.text, conversion.opts)
Assert.len(parsed.chapters, 3)
Assert.eq(parsed.chapters[2].title, "01", "数字小节必须进入 EPUB 自己的目录")
Assert.eq(parsed.chapters[3].title, "02")
Assert.is_true(conversion.opts.reflow)
Assert.eq(conversion.opts.tail_html, Content.FOOTER, "整篇 EPUB 只在文末留章评区，不进入内部目录")
conversion.progress("排版", 1, 3)
Assert.eq(Themed.last("progress_dialog").updates[1][2], 1)
local file = assert(io.open(dest, "wb")); file:write("epub fixture"); file:close()
conversion.cb(true)
Assert.eq(result, dest)
Assert.is_nil(err)
local id = Store.identityFor(dest)
Assert.eq(id.stable_id, identity.stable_id)
Assert.is_nil(id.chapter_idx, "EPUB 是整本身份，不能被源目录覆盖内部小节")
local migrated = ProgressDB.get(identity.source_id, identity.stable_id)
Assert.eq(migrated.fraction, .4)
Assert.is_nil(migrated.locator)
Assert.is_nil(migrated.chapter_idx)
Assert.is_nil(migrated.page)
Assert.is_true(Themed.last("progress_dialog").closed)

local count = downloads
Story.openAsync({}, identity, nil, {}, done)
Stubs.flush()
Assert.eq(downloads, count, "本地 EPUB 快开不联网、不重复转换")
Assert.eq(result, dest)

reset(html)
NoteDB.upsert(identity.source_id, identity.stable_id, 1, '[{"text":"原有划线"}]')
count = #conversions
Story.openAsync({}, identity, nil, {}, done)
Assert.eq(result, original)
Assert.eq(#conversions, count)
Assert.eq(Themed.last("toast").text, "已有划线，保留原始排版")
Assert.matches(NoteDB.get(identity.source_id, identity.stable_id, 1).payload, "原有划线")
reset("<!--moon:temp-->" .. html)
Story.openAsync({}, identity, nil, {}, done)
Assert.eq(result, original)
Assert.eq(#conversions, count, "购买提示不能被打包成永久 EPUB")
reset('<html><body><p>配图</p><img src="data:image/png;base64,fixture"/></body></html>')
Story.openAsync({}, identity, nil, {}, done)
Assert.eq(result, original)
Assert.eq(#conversions, count)
Assert.eq(Themed.last("toast").text, "短篇含图片，保留原始排版")

reset(html)
Story.openAsync({}, identity, nil, {}, done)
conversions[#conversions].cb(nil, "zip failed")
Assert.is_nil(result)
Assert.eq(err, "zip failed")
Assert.eq(BookDB.get(identity.source_id, identity.stable_id).path, original)
Assert.is_true(Themed.last("progress_dialog").closed)

reset(html)
local job = Story.openAsync({}, identity, nil, {}, done)
local before = calls
file = assert(io.open(dest .. ".part", "wb")); file:write("partial"); file:close()
job.cancel()
Assert.is_true(conversions[#conversions].cancelled)
Assert.is_true(Themed.last("progress_dialog").closed)
Assert.is_nil(io.open(dest .. ".part", "rb"))
conversions[#conversions].cb(true)
Assert.eq(calls, before)

reset(html)
ProgressDB.upsert(identity.source_id, identity.stable_id, { fraction = .5, locator = "keep-until-commit" })
Story.openAsync({}, identity, nil, {}, done)
local upsert = ProgressDB.upsert
ProgressDB.upsert = function() return false end
conversions[#conversions].cb(true)
ProgressDB.upsert = upsert
Assert.is_nil(result)
Assert.eq(err, "阅读进度保存失败")
Assert.eq(BookDB.get(identity.source_id, identity.stable_id).path, original, "进度失败须回滚 EPUB 路径登记")
Assert.eq(ProgressDB.get(identity.source_id, identity.stable_id).locator, "keep-until-commit")
DB.close()
Content.upgradeStory = upgrade_story
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
os.remove(original)
os.remove(dest)
os.remove(dest .. ".part")
