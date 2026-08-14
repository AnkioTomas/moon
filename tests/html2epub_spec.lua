--[[--
html2epub 离线用例

@module tests.html2epub_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local Html2Epub = require("html2epub")

-- xmlEscape
do
    Assert.eq(Html2Epub._xmlEscape([[a<b>"c"&]]), [[a&lt;b&gt;&quot;c&quot;&amp;]])
end

-- collect / rewrite image srcs
do
    local html = [[<p>x</p><img src="https://a/x.png"><img src='https://b/y.jpg' alt="y"><img src=foo.png>]]
    local srcs = Html2Epub._collectImageSrcs(html)
    Assert.eq(#srcs, 3)
    Assert.eq(srcs[1], "https://a/x.png")
    Assert.eq(srcs[2], "https://b/y.jpg")
    Assert.eq(srcs[3], "foo.png")

    local out = Html2Epub._rewriteImageSrcs(html, {
        ["https://a/x.png"] = "images/img_001.png",
        ["https://b/y.jpg"] = "images/img_002.jpg",
        ["foo.png"] = "images/img_003.png",
    })
    Assert.is_true(out:find("images/img_001.png", 1, true) ~= nil)
    Assert.is_true(out:find("images/img_002.jpg", 1, true) ~= nil)
    Assert.is_true(out:find("images/img_003.png", 1, true) ~= nil)
    Assert.is_true(out:find("https://a/x.png", 1, true) == nil)
end

-- plain text → paragraphs
do
    local body = Html2Epub._ensureHtmlBody("hello\nworld")
    Assert.is_true(body:find("<p>hello</p>", 1, true) ~= nil)
    Assert.is_true(body:find("<p>world</p>", 1, true) ~= nil)
end

-- sniff jpeg
do
    local ext, mime = Html2Epub._sniffImage("\255\216\255" .. "xxxx")
    Assert.eq(ext, ".jpg")
    Assert.eq(mime, "image/jpeg")
end

-- build：逐章 get_chapter + 无图打包（stub Archiver / Task）
do
    local added = {}
    local opened
    local saved = {
        archiver_loaded = package.loaded["ffi/archiver"],
        archiver_preload = package.preload["ffi/archiver"],
        task_loaded = package.loaded["utils.task"],
        task_preload = package.preload["utils.task"],
        html2epub = package.loaded["html2epub"],
    }

    package.loaded["ffi/archiver"] = nil
    package.preload["ffi/archiver"] = function()
        return {
            Writer = {
                new = function()
                    return {
                        open = function(_, path, fmt)
                            opened = { path = path, fmt = fmt }
                            return true
                        end,
                        setZipCompression = function() return true end,
                        addFileFromMemory = function(_, path, content)
                            added[#added + 1] = { path = path, n = #tostring(content) }
                            return true
                        end,
                        close = function() end,
                        err = nil,
                    }
                end,
            },
        }
    end

    local old_rename = os.rename
    local old_remove = os.remove
    os.rename = function()
        return true
    end
    os.remove = function() return true end

    package.loaded["utils.task"] = nil
    package.preload["utils.task"] = function()
        return {
            run = function(worker, opts)
                local write_buf
                local ok, err = pcall(worker, function(data)
                    write_buf = data
                end)
                if not ok then
                    if opts and opts.on_failed then
                        opts.on_failed(err)
                    end
                elseif opts and opts.on_done then
                    opts.on_done(write_buf)
                end
                return { abort = function() end }
            end,
        }
    end

    package.loaded["html2epub"] = nil
    package.loaded["html2epub.init"] = nil
    local M = require("html2epub")

    local got_ok, got_err
    local chapter_calls = 0
    local progress = {}

    M.build({
        dest = "/tmp/moon-test-html2epub.epub",
        title = "测试书",
        author = "作者甲",
        chapters = {
            { title = "第一章" },
            { title = "第二章" },
        },
        get_chapter = function(i, ch, cb)
            chapter_calls = chapter_calls + 1
            cb("<p>chapter " .. i .. " " .. ch.title .. "</p>")
        end,
        on_progress = function(ev)
            progress[#progress + 1] = ev.phase
        end,
    }, function(ok, err)
        got_ok, got_err = ok, err
    end)

    Stubs.flush()
    Assert.eq(chapter_calls, 2)
    Assert.eq(got_ok, true)
    Assert.eq(got_err, nil)
    Assert.eq(opened and opened.fmt, "epub")

    local paths = {}
    for _, it in ipairs(added) do
        paths[it.path] = true
    end
    Assert.is_true(paths["mimetype"])
    Assert.is_true(paths["META-INF/container.xml"])
    Assert.is_true(paths["OEBPS/content.opf"])
    Assert.is_true(paths["OEBPS/toc.ncx"])
    Assert.is_true(paths["OEBPS/chapter_001.xhtml"])
    Assert.is_true(paths["OEBPS/chapter_002.xhtml"])

    local saw_chapter = false
    local saw_pack = false
    for _, p in ipairs(progress) do
        if p == "chapter" then saw_chapter = true end
        if p == "pack" then saw_pack = true end
    end
    Assert.is_true(saw_chapter)
    Assert.is_true(saw_pack)

    os.rename = old_rename
    os.remove = old_remove
    package.preload["ffi/archiver"] = saved.archiver_preload
    package.loaded["ffi/archiver"] = saved.archiver_loaded
    package.preload["utils.task"] = saved.task_preload
    package.loaded["utils.task"] = saved.task_loaded
    package.loaded["html2epub"] = saved.html2epub
    package.loaded["html2epub.init"] = nil
end
