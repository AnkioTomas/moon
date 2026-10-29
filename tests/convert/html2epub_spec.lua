--[[--
html2epub 离线用例

@module tests.convert.html2epub_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local Html2Epub = require("convert.html2epub")

-- write：章节 HTML 打包（stub Archiver）
do
    local added = {}
    local opened
    local fail_path
    local saved = {
        archiver_loaded = package.loaded["ffi/archiver"],
        archiver_preload = package.preload["ffi/archiver"],
        html2epub = package.loaded["convert.html2epub"],
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
                            added[#added + 1] = { path = path, content = tostring(content) }
                            return path ~= fail_path
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

    package.loaded["convert.html2epub"] = nil
    local M = require("convert.html2epub")

    local got_ok, got_err = M.write({
        dest = "/tmp/moon-test-html2epub.epub",
        title = "测试书",
        author = "作者甲",
        chapters = {
            { title = "第一章", html = "<p>chapter 1</p>" },
            { title = "第二章", html = "<p>chapter 2</p>", toc = false },
        },
    })

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
    for _, it in ipairs(added) do
        if it.path == "OEBPS/toc.ncx" then
            Assert.is_true(it.content:find("第一章", 1, true) ~= nil)
            Assert.is_true(it.content:find("第二章", 1, true) == nil)
        end
        if it.path == "OEBPS/chapter_002.xhtml" then
            Assert.is_true(it.content:find("<p>chapter 2</p>", 1, true) ~= nil)
        end
    end

    -- 关键条目写失败：必须报错，不能 rename 成品。
    for _, path in ipairs({ "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/toc.ncx" }) do
        fail_path = path
        local renamed = false
        os.rename = function() renamed = true; return true end
        got_ok, got_err = M.write({
            dest = "/tmp/moon-test-html2epub.epub",
            title = "测试书",
            chapters = { { title = "第一章", html = "<p>x</p>" } },
        })
        Assert.is_nil(got_ok, path)
        Assert.matches(tostring(got_err), "写入 epub 失败")
        Assert.is_false(renamed, path)
    end

    os.rename = old_rename
    os.remove = old_remove
    package.preload["ffi/archiver"] = saved.archiver_preload
    package.loaded["ffi/archiver"] = saved.archiver_loaded
    package.loaded["convert.html2epub"] = saved.html2epub
end
