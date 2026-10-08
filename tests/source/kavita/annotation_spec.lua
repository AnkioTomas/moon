local Assert = require("support.assert")
local JsonStub = require("support.json_stub")

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local toc_cache = { { idx = 1, chapterId = 11, volumeId = 3, libraryId = 8, pages = 120, format = "epub" } }
package.preload["source.toc"] = function()
    return {
        read = function() return toc_cache end,
        put = function(_, _, list) toc_cache = list; return true end,
        drop = function() end,
    }
end

local entries = {
    ["META-INF/container.xml"] =
        '<container><rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    ["OPS/content.opf"] =
        '<package><manifest><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/></manifest>'
        .. '<spine><itemref idref="c1"/></spine></package>',
    ["OPS/chapter1.xhtml"] =
        "<html><body><p>Alpha paragraph one.</p><p>Beta paragraph two.</p><p>中文测试段落。</p></body></html>",
}
local order = { "META-INF/container.xml", "OPS/content.opf", "OPS/chapter1.xhtml" }
package.preload["ffi/archiver"] = function()
    return {
        Reader = {
            new = function()
                local scanned = {}
                local i = 0
                return {
                    open = function() return true end,
                    close = function() end,
                    iterate = function()
                        return function()
                            i = i + 1
                            local key = order[i]
                            if not key then return nil end
                            scanned[key] = true
                            return { path = key, mode = "file" }
                        end
                    end,
                    extractToMemory = function(_, key)
                        if not scanned[key] then return nil end
                        return entries[key]
                    end,
                }
            end,
        },
    }
end

local create_calls = {}
local update_calls = {}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            local url = opts.url or ""
            if url:match("/api/Annotation/create") then
                create_calls[#create_calls + 1] = JsonStub.decode(opts.body)
                cb({ code = 200, body = JsonStub.encode({ id = 777 }) })
            elseif url:match("/api/Annotation/update") then
                update_calls[#update_calls + 1] = JsonStub.decode(opts.body)
                cb({ code = 200, body = JsonStub.encode({ id = 777 }) })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local Paths = require("utils.paths")
Paths.ensureBookWork("42", "kavita")
os.remove(Paths.bookWorkDir("42", "kavita") .. "/kavita-annotations.json")

local Kavita = require("source.kavita")
local source = Kavita.new()
local identity = {
    source_id = "kavita", stable_id = "42",
    book = { format = "epub", path = "/fake/book.epub" },
}
local annotations = {
    {
        drawer = "lighten",
        text = "Beta paragraph two",
        note = "my note",
        pos0 = "/body/DocFragment[1]/body/p[2]/text().0",
    },
}

local ok
source:pushNotesAsync(identity, annotations, function(o) ok = o end)
Assert.is_true(ok)
Assert.len(create_calls, 1)
local payload = create_calls[1]
Assert.eq(payload.chapterId, 11)
Assert.eq(payload.seriesId, 42)
Assert.eq(payload.volumeId, 3)
Assert.eq(payload.libraryId, 8)
Assert.eq(payload.ownerUserId, 0)
Assert.eq(payload.xPath, "//body/p[2]")
Assert.eq(payload.endingXPath, "//body/p[2]")
Assert.eq(payload.selectedText, "Beta paragraph two")
Assert.eq(payload.comment, "my note")
Assert.eq(payload.commentHtml, "")
Assert.eq(payload.selectedSlotIndex, 0)
Assert.eq(payload.pageNumber, 0)
Assert.eq(payload.highlightCount, #"Beta paragraph two")
Assert.eq(payload.containsSpoiler, false)

-- 幂等：同一 pos0 第二次不再建
local ok2
source:pushNotesAsync(identity, annotations, function(o) ok2 = o end)
Assert.is_true(ok2)
Assert.len(create_calls, 1)

-- 已建注解的备注变更 → update（不重复 create）
local ok_up
source:pushNotesAsync(identity, {
    { drawer = "lighten", text = "Beta paragraph two", note = "edited note",
      pos0 = "/body/DocFragment[1]/body/p[2]/text().0" },
}, function(o) ok_up = o end)
Assert.is_true(ok_up)
Assert.len(create_calls, 1)
Assert.len(update_calls, 1)
Assert.eq(update_calls[1].id, 777)
Assert.eq(update_calls[1].comment, "edited note")
Assert.eq(update_calls[1].xPath, "//body/p[2]")
Assert.eq(update_calls[1].chapterId, 11)
-- 备注不变则不重复 update
source:pushNotesAsync(identity, {
    { drawer = "lighten", text = "Beta paragraph two", note = "edited note",
      pos0 = "/body/DocFragment[1]/body/p[2]/text().0" },
}, function() end)
Assert.len(update_calls, 1)

-- 文本匹配失败：降级为空 xPath，仍按 pos0 页号建
local ok3
source:pushNotesAsync(identity, {
    { drawer = "lighten", text = "text not present anywhere", pos0 = "/body/DocFragment[1]/body/p[9]/text().0" },
}, function(o) ok3 = o end)
Assert.is_true(ok3)
Assert.len(create_calls, 2)
Assert.eq(create_calls[2].xPath, "")
Assert.eq(create_calls[2].pageNumber, 0)

-- 非 EPUB 跳过
local skip = { source_id = "kavita", stable_id = "42", book = { format = "pdf", path = "/fake/b.pdf" } }
local ok4
source:pushNotesAsync(skip, annotations, function(o) ok4 = o end)
Assert.is_true(ok4)
Assert.len(create_calls, 2)

-- 书行无 format 时从 toc 条目取（books 表没有 format 列，曾因此把所有注解误判非 EPUB 跳过）
toc_cache = { { idx = 1, chapterId = 12, libraryId = 8, pages = 120, format = "epub" } }
create_calls = {}
source:pushNotesAsync(
    { source_id = "kavita", stable_id = "44" },
    { { drawer = "lighten", text = "Alpha paragraph one", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" } },
    function() end
)
Assert.len(create_calls, 1)
Assert.eq(create_calls[1].chapterId, 12)

-- toc 条目 format=cbz → 漫画跳过
toc_cache = { { idx = 1, chapterId = 13, libraryId = 8, pages = 120, format = "cbz" } }
create_calls = {}
source:pushNotesAsync(
    { source_id = "kavita", stable_id = "45" },
    { { drawer = "lighten", text = "Alpha paragraph one", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" } },
    function() end
)
Assert.len(create_calls, 0)

-- 非 ASCII：highlightCount 是字符数（对齐 JS String.length / Kavita），不是 Lua 字节数
toc_cache = { { idx = 1, chapterId = 14, libraryId = 8, pages = 120, format = "epub" } }
create_calls = {}
source:pushNotesAsync(
    { source_id = "kavita", stable_id = "46", book = { format = "epub", path = "/fake/book.epub" } },
    { { drawer = "lighten", text = "中文测试段落。", pos0 = "/body/DocFragment[1]/body/p[3]/text().0" } },
    function() end
)
Assert.len(create_calls, 1)
Assert.eq(create_calls[1].xPath, "//body/p[3]")
Assert.eq(create_calls[1].highlightCount, 7) -- 7 字符，不是 21 字节
