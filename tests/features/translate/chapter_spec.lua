--[[-- features.translate.chapter：双语章路径、任务输入、开章时的就绪判断（不后台翻译）。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function() return require("support.json_stub") end
package.loaded["json"] = nil

local settings = {}
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
package.preload["workers.job"] = function()
    return { run = function(fn, opts)
        local ok, result = pcall(fn)
        if ok then opts.on_done(result) else opts.on_failed(result) end
    end }
end
package.preload["apps/reader/readerui"] = function() return {} end
local requests = {}
package.preload["features.translate.edge"] = function()
    return { translateListAsync = function(texts, _lang, _src, cb)
        requests[#requests + 1] = texts
        local out = {}
        for i, text in ipairs(texts) do out[i] = "T:" .. text end
        cb(out)
    end }
end

local Paths = require("utils.paths")
local ChapterBi = require("features.translate.chapter")

-- 路径：双语章在 bilingual/ 下，能换算回原章；旧的同目录文件也能换算；普通文件不变。
Assert.eq(Paths.bilingualChapterPath("/w/3.html"), "/w/bilingual/3.html")
Assert.eq(Paths.chapterOrigin("/w/bilingual/3.html"), "/w/3.html")
Assert.eq(Paths.chapterOrigin("/w/3.bi-edge-en.html"), "/w/3.html")
Assert.eq(Paths.chapterOrigin("/w/3.html"), "/w/3.html")
Assert.eq(Paths.chapterOrigin("/w/bilingual/book.epub"), "/w/bilingual/book.epub")

local identity = { source_id = "wechat", stable_id = "chapter-bi-spec" }
local work = Paths.bookWorkDir(identity.stable_id, identity.source_id)
assert(Paths.ensureDir(work))

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- 未开启：不处理。
local origin = Paths.chapterPath(identity.stable_id, 1, identity.source_id)
write(origin, "<html><body><p>Hello</p></body></html>")
Assert.is_nil(ChapterBi.resolve(identity, 1, origin))
Assert.eq(#ChapterBi.variants(identity, origin), 0)

-- 开启但双语章没生成：开原章，不在后台偷偷翻（翻译只由面板触发，走整书进度窗）。
local conf = { engine = "edge", lang = "zh" }
ChapterBi.set(identity, conf)
Assert.eq(ChapterBi.get(identity).engine, "edge")
Assert.eq(ChapterBi.variants(identity, origin)[1], ChapterBi.pathFor(origin, conf))
Assert.eq(ChapterBi.variants(identity, origin)[2], work .. "/1.bi-edge-zh.html")
Assert.is_nil(ChapterBi.resolve(identity, 1, origin))
Assert.eq(#requests, 0, "开章不发翻译请求")

-- 任务输入：单章 dom，source 即原章（完成不删原章、不写 meta），缓存与整书共用。
local input = ChapterBi.input(identity, origin, conf)
local dest = ChapterBi.pathFor(origin, conf)
Assert.is_true(input.chapter)
Assert.eq(input.kind, "dom")
Assert.eq(input.source, origin)
Assert.eq(input.dest, dest)
Assert.eq(input.cache, work .. "/bilingual/edge-zh.jsonl")

-- 双语章就绪：直接用。
write(dest, "<html><body><p>Hello</p><p>你好</p></body></html>")
Assert.eq(ChapterBi.resolve(identity, 1, origin), dest)

-- 原章更新后双语章作废。
local lfs = require("libs/libkoreader-lfs")
if lfs.touch then
    lfs.touch(dest, 1000, 1000)
    Assert.is_nil(ChapterBi.resolve(identity, 1, origin))
    local old = ChapterBi.legacyPath(origin, conf)
    write(old, "<html/>")
    lfs.touch(origin, 2000, 2000)
    lfs.touch(old, 5000, 5000)
    Assert.eq(ChapterBi.resolve(identity, 1, origin), old, "旧排版的文件还在就用它")
end

-- 关闭。
ChapterBi.set(identity, nil)
Assert.is_nil(ChapterBi.get(identity))
require("ffi/util").purgeDir(work)
