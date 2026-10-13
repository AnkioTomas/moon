--[[-- features.translate.bilingual：分批、整书任务（续跑 / 失败 / 取消）、切回原文的位置换算。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function() return require("support.json_stub") end
package.loaded["json"] = nil

-- 子进程同步跑完。
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            local ok, result = pcall(worker)
            if ok then opts.on_done(result) else opts.on_failed(result) end
            return { cancel = function() end }
        end,
    }
end

-- Edge 桩：请求挂起，由用例逐个应答。
local requests = {}
package.preload["features.translate.edge"] = function()
    return {
        translateListAsync = function(texts, lang, source_lang, cb)
            local req = { texts = texts, lang = lang, source_lang = source_lang, cb = cb }
            req.cancel = function() req.cancelled = true end
            requests[#requests + 1] = req
            return req
        end,
    }
end

local session
package.preload["reader.session"] = function()
    return { current = function() return session end }
end

local Bilingual = require("features.translate.bilingual")

-- 可用：整本源的流式文档；章节源（含全本缓存后的整本）、固定版式、无会话一律不可用。
local rolling = { rolling = {}, document = { file = "/books/bilingual-spec.epub" } }
Assert.is_false(Bilingual.available(rolling))
session = { identity = { source = { type = "book" } } }
Assert.is_true(Bilingual.available(rolling))
Assert.is_false(Bilingual.available({}))
session = { identity = { source = { type = "chapter" } } }
Assert.is_false(Bilingual.available(rolling))
session = { identity = { source = { type = "chapter" }, chapter_idx = 3 } }
Assert.is_false(Bilingual.available(rolling))
session = { identity = {} }
Assert.is_false(Bilingual.available(rolling), "属主源已卸载（第三方源插件）不可用，不能抛错")

-- 读别的衍生版（排版版）时不能再套一层双语：二级衍生版的划线收不回笔记库
do
    local Paths = require("utils.paths")
    local identity = { source_id = "local", stable_id = "/books/bilingual-chain.epub", source = { type = "book" } }
    local reflow_dir = Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/reflow"
    assert(Paths.ensureDir(reflow_dir))
    local meta = assert(io.open(reflow_dir .. "/meta.json", "wb"))
    meta:write(require("support.json_stub").encode({ origin = identity.stable_id, file = reflow_dir .. "/book.epub" }))
    meta:close()
    session = { identity = identity }
    Assert.is_false(Bilingual.available({ rolling = {}, document = { file = reflow_dir .. "/book.epub" } }))
    Assert.is_true(Bilingual.available({ rolling = {}, document = { file = identity.stable_id } }))
    require("ffi/util").purgeDir(Paths.bookWorkDir(identity.stable_id, identity.source_id))
end

local function sizes(list)
    local out = {}
    for i, batch in ipairs(list) do out[i] = #batch end
    return table.concat(out, ",")
end

-- 分批：按段数上限切；超字符上限另起一批；单段超长也自成一批。
Assert.eq(sizes(Bilingual._batches({ "a", "b", "c", "d", "e" }, 2, 100)), "2,2,1")
Assert.eq(sizes(Bilingual._batches({ "aaaa", "bbbb", "cc" }, 10, 6)), "1,2")
Assert.eq(sizes(Bilingual._batches({ string.rep("x", 50), "y" }, 10, 6)), "1,1")
Assert.eq(sizes(Bilingual._batches({}, 10, 6)), "")

local dir = require("support.config").dir() .. "/bilingual_spec"
os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function has(s, part)
    Assert.is_true(type(s) == "string" and s:find(part, 1, true) ~= nil, "missing: " .. part)
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local SOURCE = '<?xml version="1.0" encoding="UTF-8"?>\n<FictionBook><body><section>'
    .. "<title><p>Chapter</p></title><p>Hello</p><p>World</p><p>Hello</p></section></body></FictionBook>"

local function input(name)
    write(dir .. "/" .. name .. ".fb2", SOURCE)
    return {
        kind = "dom",
        origin = "/books/a.txt",
        source = dir .. "/" .. name .. ".fb2",
        cache = dir .. "/" .. name .. ".jsonl",
        dest = dir .. "/" .. name .. "-book.fb2",
        dir = dir,
        engine = "edge",
        lang = "zh",
    }
end

local function start(spec)
    local reports, results = {}, {}
    local handle = Bilingual._task(spec)(function(text, count, total)
        reports[#reports + 1] = { text = text, count = count, total = total }
    end, function(result)
        results[#results + 1] = result
    end)
    return handle, reports, results
end

-- 续跑：缓存里已有 Chapter，末行是被杀时写了一半的残行；只翻其余去重后的段落。
local spec = input("resume")
write(spec.cache, '["Chapter","章"]\n["Hel')
local _handle, reports, results = start(spec)
Assert.len(requests, 1)
Assert.eq(table.concat(requests[1].texts, "|"), "Hello|World")
Assert.eq(requests[1].lang, "zh")
Assert.is_nil(requests[1].source_lang)
Assert.eq(reports[#reports].count, 1)
Assert.eq(reports[#reports].total, 3)
Assert.len(results, 0)
requests[1].cb({ "你好", "世界" })
Assert.len(results, 1)
Assert.is_true(results[1].ok)
Assert.eq(results[1].file, spec.dest)
local out = read(spec.dest)
has(out, '<title><p>Chapter<br/><span class="moon-tr" style="display:block">章</span></p></title>')
has(out, '<p>Hello<br/><span class="moon-tr" style="display:block">你好</span></p><p>World<br/><span class="moon-tr" style="display:block">世界</span></p>'
    .. '<p>Hello<br/><span class="moon-tr" style="display:block">你好</span></p>')
Assert.is_nil(read(spec.source))
Assert.is_nil(read(spec.dest .. ".part"))
has(read(dir .. "/meta.json"), '"file":"' .. spec.dest .. '"')
has(read(dir .. "/meta.json"), '"origin":"/books/a.txt"')
has(read(spec.cache), '["Hel\n["Hello","你好"]\n["World","世界"]\n')

-- 全部命中缓存：不发请求，直接生成。
requests = {}
local again = input("resume")
local _h2, _r2, results2 = start(again)
Assert.len(requests, 0)
Assert.is_true(results2[1].ok)

-- 失败：标 retry，已成功的批次留在缓存里供重试续跑。
requests = {}
local failing = input("fail")
failing.engine = "edge"
local _h3, _r3, results3 = start(failing)
Assert.len(requests, 1)
requests[1].cb(nil, nil, "HTTP 500")
Assert.len(results3, 1)
Assert.is_false(results3[1].ok)
Assert.is_true(results3[1].retry)
Assert.eq(results3[1].err, "HTTP 500")
Assert.is_nil(read(failing.dest))
Assert.not_nil(read(failing.source))

-- 取消：在飞请求被取消，之后的应答不再回调。
requests = {}
local cancelled = input("cancel")
local handle4, _r4, results4 = start(cancelled)
handle4:cancel()
Assert.is_true(requests[1].cancelled)
requests[1].cb({ "a", "b", "c" })
Assert.len(results4, 0)
Assert.is_nil(read(cancelled.dest))

-- 切回原文：位置落在译文 span 里时退到所在段落；原书自带的 span 不动。
local document = {
    getHTMLFromXPointer = function(_self, xp)
        if xp == "/body/DocFragment[2]/body/p[5]/span[2]" then return '<span class="moon-tr" style="display:block">译</span>' end
        if xp == "/body/DocFragment[2]/body/p[5]/span" then return '<span class="em">x</span>' end
        return nil
    end,
}
Assert.eq(Bilingual._originalXPointer(document, "/body/DocFragment[2]/body/p[5]/span[2]/text().3"),
    "/body/DocFragment[2]/body/p[5]")
Assert.eq(Bilingual._originalXPointer(document, "/body/DocFragment[2]/body/p[5]/span/text().1"),
    "/body/DocFragment[2]/body/p[5]/span/text().1")
Assert.eq(Bilingual._originalXPointer(document, "/body/DocFragment[2]/body/p[6]/text().0"),
    "/body/DocFragment[2]/body/p[6]/text().0")

os.execute("rm -rf '" .. dir .. "'")
