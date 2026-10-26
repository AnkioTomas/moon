--[[-- features.translate.bilingual：分批、整书任务（续跑 / 失败）、前台进度窗、切回原文的位置换算。 --]]

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

-- 可用：流式文档（整本源与章节源）；固定版式（含漫画 CBZ）、无会话不可用。
local rolling = { rolling = {}, document = { file = "/books/bilingual-spec.epub" } }
Assert.is_false(Bilingual.available(rolling))
session = { identity = { source = { type = "book" } } }
Assert.is_true(Bilingual.available(rolling))
Assert.is_false(Bilingual.available({}))
session = { identity = { source = { type = "chapter" }, chapter_idx = 3 } }
Assert.is_true(Bilingual.available(rolling))
Assert.is_false(Bilingual.available({ document = { file = "/x/1.cbz" } }), "漫画不是流式文档")
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

-- 章节源（input.chapter）：同一任务流程翻单章；原章（source）保留，不写 meta。
do
    os.remove(dir .. "/meta.json")
    local ch = input("chapter")
    ch.chapter = true
    local _hc, _rc, results_c = start(ch)
    Assert.len(requests, 1)
    requests[1].cb({ "章", "你好", "世界" })
    requests = {}
    Assert.is_true(results_c[1].ok)
    has(read(ch.dest), "你好")
    Assert.not_nil(read(ch.source), "原章不删")
    Assert.is_nil(read(dir .. "/meta.json"), "章节不写整书 meta")
end

-- 失败：回调错误，已成功的批次留在缓存里，重来时续跑。
requests = {}
local failing = input("fail")
failing.engine = "edge"
local _h3, _r3, results3 = start(failing)
Assert.len(requests, 1)
requests[1].cb(nil, nil, "HTTP 500")
Assert.len(results3, 1)
Assert.is_false(results3[1].ok)
Assert.eq(results3[1].err, "HTTP 500")
Assert.is_nil(read(failing.dest))
Assert.not_nil(read(failing.source))

-- 取消：停掉在途请求，之后的应答不再结束任务；半截 .part 删掉，已译段落留在缓存
requests = {}
local cancelling = input("cancel")
local handle4, _r4, results4 = start(cancelling)
write(cancelling.dest .. ".part", "half")
Assert.len(requests, 1)
handle4.cancel()
Assert.is_true(requests[1].cancelled)
requests[1].cb({ "你好", "世界" })
Assert.len(results4, 0, "取消后应答不再结束任务")
Assert.is_nil(read(cancelling.dest .. ".part"))

-- 入口：入后台任务队列（每本书一个 key，可取消、可转后台）；正在跑时再点入口只跟随进度
do
    local Themed = require("support.theme_stubs")
    Themed.install()
    package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
    package.loaded["ui/network/manager"] = nil
    package.preload["ui/translator"] = function() return { getTargetLanguage = function() return "zh" end } end
    package.preload["features.translate.languages"] = function()
        return { displayName = function(_translator, code) return code end }
    end
    package.preload["ai"] = function() return { isConfigured = function() return false end } end
    local started, followed, running
    package.preload["workers.ui.task_dialog"] = function()
        return { start = function(spec) started = spec end, follow = function(task) followed = task end }
    end
    package.preload["workers.tasks"] = function() return { get = function(key) return running and running.key == key and running or nil end } end
    local reader_instance = {}
    package.preload["apps/reader/readerui"] = function() return reader_instance end
    session = { identity = { source_id = "local", stable_id = "/books/bilingual-entry.epub",
        source = { type = "book" }, book = { title = "书" } } }
    local ui = { rolling = {}, document = {
        file = "/books/bilingual-entry.epub",
        getXPointer = function() return "/body/p[1]" end,
    } }
    Bilingual.show(ui)
    local sheet = Themed.last("sheet")
    Assert.eq(sheet.items[2].text, "用 Edge 翻译全书")
    sheet.items[2].callback()
    Assert.eq(started.key, "bilingual\0local\0/books/bilingual-entry.epub")
    Assert.eq(started.kind, "convert")
    Assert.eq(started.title, "书（双语）")
    Assert.is_true(started.restartable, "可取消、休眠断网后续跑")
    ---@type string[], table|nil
    local reports, result = {}, nil
    local h = started.run(function(text) reports[#reports + 1] = text end, function(r) result = r end)
    Assert.eq(reports[1], "正在分析全书段落")
    Assert.is_false(result.ok, "原书不存在：分析失败")
    Assert.not_nil(h.cancel)
    started.on_done(result)
    Assert.matches(Themed.last("toast").text, "双语翻译失败")
    -- 完成：书已关（或换了书）只提示；还在读原书则询问打开
    started.on_done({ ok = true, file = "/x" })
    Assert.eq(Themed.last("toast").text, "双语对照已生成")
    reader_instance.instance = ui
    started.on_done({ ok = true, file = "/x" })
    Assert.eq(Themed.last("confirm").text, "双语对照已生成，现在打开？")
    -- 重复：同一本书正在翻译，入口不再弹菜单，直接跟随
    running = { key = started.key }
    local sheets = #Themed.made
    Bilingual.show(ui)
    Assert.eq(followed, running)
    Assert.eq(#Themed.made, sheets)
    require("ffi/util").purgeDir(require("utils.paths").bookWorkDir(session.identity.stable_id, "local"))
end

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
