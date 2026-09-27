--[[-- book.reflow 离线用例。
@module tests.book.reflow_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local Reflow = require("book.reflow")
local Text2Epub = require("convert.text2epub")

local function identity(path, stable_id)
    return {
        source_id = "local",
        stable_id = stable_id or path,
        source = { id = "local", replaceBookAsync = function() end },
        book = { title = "测试", authors = "作者", path = path },
    }
end

Assert.is_true(Reflow.canReflow(identity("/books/a.txt")))
Assert.is_true(Reflow.canReflow(identity("/books/a.mobi")))
Assert.is_false(Reflow.canReflow(identity("/books/a.epub")))
Assert.is_false(Reflow.canReflow({ source_id = "moon", stable_id = "/books/a.txt" }))
Assert.is_true(Reflow.canReflow(identity("/books/A/B/a.txt", "webdav://A/B/a.txt")), "WebDAV 书按本地副本排版")
Assert.is_false(Reflow.canReflow(identity(nil, "webdav://A/B/a.txt")), "没下载到本地不能排版")

local parsed = Text2Epub.parse("第一章 开始\n正文\n\n第二章 继续\n更多", {
    title = "测试",
    reflow = true,
})
local titles = Reflow._tocTitles(parsed)
Assert.len(titles, 2)
Assert.eq(titles[1], "第一章 开始")
Assert.eq(titles[2], "第二章 继续")

local analyze_done = false
local preview_path = os.tmpname() .. ".txt"
local preview_file = io.open(preview_path, "w")
preview_file:write("第一章 开始\n正文\n\n第二章 继续\n更多")
preview_file:close()
Reflow.analyzeAsync(identity(preview_path), function(titles_out, err)
    analyze_done = true
    Assert.is_nil(err)
    Assert.len(titles_out, 2)
    Assert.eq(titles_out[1], "第一章 开始")
end)
Stubs.flush()
Assert.is_true(analyze_done)
os.remove(preview_path)

-- 转换产物交给源按身份替换：读写本地副本，替换用 stable_id；成功交出新路径，失败清掉临时文件。
do
    local original_build = Text2Epub.build
    local built
    Text2Epub.build = function(opts, cb)
        built = opts
        cb(true)
        return { cancel = function() end }
    end
    local book = identity("/books/A/b.txt", "webdav://A/b.txt")
    local replaced
    book.source.replaceBookAsync = function(_, temp, stable_id, cb)
        replaced = { temp = temp, stable_id = stable_id }
        cb("/books/A/b.epub")
    end
    local new_path, err
    Reflow.applyAsync(book, function(p, e) new_path, err = p, e end)
    Assert.eq(built.source, "/books/A/b.txt")
    Assert.eq(built.dest, "/books/A/b.epub.moon-reflow")
    Assert.eq(replaced.temp, "/books/A/b.epub.moon-reflow")
    Assert.eq(replaced.stable_id, "webdav://A/b.txt")
    Assert.eq(new_path, "/books/A/b.epub")
    Assert.is_nil(err)

    local removed = {}
    local original_remove = os.remove
    os.remove = function(p) removed[#removed + 1] = p end
    book.source.replaceBookAsync = function(_, _, _, cb) cb(nil, "更新书目失败") end
    Reflow.applyAsync(book, function(p, e) new_path, err = p, e end)
    os.remove = original_remove
    Text2Epub.build = original_build
    Assert.is_nil(new_path)
    Assert.eq(err, "更新书目失败")
    Assert.contains(removed, "/books/A/b.epub.moon-reflow")
end
