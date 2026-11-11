--[[-- features.translate.bilingual：分批、整书任务（续跑 / 失败）、前台进度窗、切回原文的位置换算。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function() return require("support.json_stub") end
package.loaded["json"] = nil

-- 子进程同步跑完。回传走真正的 worker 帧，待译原文塞进结果里会在这里失败。
local job_frames = {}
package.preload["workers.job"] = function()
    local Protocol = require("workers.protocol")
    return {
        run = function(worker, opts)
            local ok, result = pcall(worker)
            if not ok then
                opts.on_failed(result)
                return { cancel = function() end }
            end
            local framed, frame = pcall(Protocol.encode, { type = "done", result = result })
            if not framed then
                opts.on_failed(frame)
                return { cancel = function() end }
            end
            job_frames[#job_frames + 1] = { name = opts.name, bytes = #frame }
            opts.on_done(result)
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

-- 分批：按段数上限切；超字符上限另起一批；单段超长也自成一批。读到解不开的行就停并报原因。
local function pendingSizes(lines, size, chars)
    local path = dir .. "/pending.jsonl"
    write(path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
    local next_batch, close, open_err, corrupt = Bilingual._pendingBatches(path, size, chars)
    Assert.is_nil(open_err)
    local out = {}
    while true do
        local batch = next_batch()
        if not batch then break end
        out[#out + 1] = #batch
    end
    close()
    return table.concat(out, ","), corrupt()
end
local function jsons(list)
    local out = {}
    for i, text in ipairs(list) do out[i] = require("support.json_stub").encode(text) end
    return out
end
Assert.eq(pendingSizes(jsons({ "a", "b", "c", "d", "e" }), 2, 100), "2,2,1")
Assert.eq(pendingSizes(jsons({ "aaaa", "bbbb", "cc" }), 10, 6), "1,2")
Assert.eq(pendingSizes(jsons({ string.rep("x", 50), "y" }), 10, 6), "1,1")
Assert.eq(pendingSizes({}, 10, 6), "")
local sizes_bad, bad = pendingSizes({ '"a"', "{broken", '"c"' }, 10, 100)
Assert.eq(sizes_bad, "1", "坏行之前的段照常成批，之后不再读")
Assert.matches(bad, "pending file corrupt")

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

-- 双语章在子目录里：相对图片和样式表改到上一级，页内锚点不动。
do
    local src = dir .. "/nest.html"
    write(src, '<html><body><p>Hello</p><img src="images/a.jpg"/>'
        .. '<link href="stylesheets.css"/><a href="#wr-fn1">x</a>'
        .. '<p style="background:url(images/bq.jpg)"></p></body></html>')
    write(dir .. "/nest.jsonl", '["Hello","你好"]\n')
    local ch = {
        kind = "dom", chapter = true, origin = src, source = src,
        cache = dir .. "/nest.jsonl", dest = dir .. "/nest-out.html",
        engine = "edge", lang = "zh",
    }
    local _hn, _rn, results_n = start(ch)
    Assert.len(requests, 0, "缓存命中不发请求")
    Assert.is_true(results_n[1].ok)
    local body = read(ch.dest)
    Assert.matches(body, 'src="../images/a.jpg"')
    Assert.matches(body, 'href="../stylesheets.css"')
    Assert.matches(body, "href=\"#wr%-fn1\"")
    Assert.matches(body, "url%(%.%./images/bq%.jpg%)")
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
Assert.not_nil(read(cancelling.cache .. ".pending"), "分析后待译原文在文件里")
handle4.cancel()
Assert.is_true(requests[1].cancelled)
requests[1].cb({ "你好", "世界" })
Assert.len(results4, 0, "取消后应答不再结束任务")
Assert.is_nil(read(cancelling.dest .. ".part"))
Assert.is_nil(read(cancelling.cache .. ".pending"))

-- 待译原文不进 worker 帧：整本书的段落超过协议 4MB 时，塞进结果会直接失败。
requests = {}
job_frames = {}
local big = input("big")
local paras = {}
for i = 1, 200 do
    paras[i] = "<p>Paragraph " .. i .. " says something distinct.</p>"
end
write(big.source, '<?xml version="1.0" encoding="UTF-8"?>\n<FictionBook><body><section>'
    .. table.concat(paras) .. "</section></body></FictionBook>")
local _hb, _rb, results_b = start(big)
Assert.eq(job_frames[1].name, "bilingual.collect")
Assert.is_true(job_frames[1].bytes < 2000, "collect frame " .. job_frames[1].bytes)
Assert.eq(requests[1].texts[1], "Paragraph 1 says something distinct.")
Assert.len(requests[1].texts, 40)
local got, last = 0, nil
while #requests > 0 do
    local req = table.remove(requests, 1)
    got = got + #req.texts
    last = req.texts[#req.texts]
    local translated = {}
    for i = 1, #req.texts do translated[i] = "译" end
    req.cb(translated)
end
Assert.eq(got, 200)
Assert.eq(last, "Paragraph 200 says something distinct.")
Assert.is_true(results_b[1].ok)
Assert.is_nil(read(big.cache .. ".pending"))

-- AI 对齐：按 id 对齐，不少返回就按短数组顺序填入；条数一致的纯字符串仍按序。
do
    local align = Bilingual._alignAiItems
    local req = { { id = 1, text = "Hello" }, { id = 2, text = "World" }, { id = 3, text = "Foo" } }
    local by_id = align(req, { { id = 3, text = "福" }, { id = 1, text = "你好" } })
    Assert.eq(by_id[1], "你好")
    Assert.is_nil(by_id[2], "缺的不能靠顺序补上")
    Assert.eq(by_id[3], "福")
    local by_str_id = align(req, { { id = "2", text = " 世界 " } })
    Assert.eq(by_str_id[2], "世界", "字符串 id 与首尾空白")
    local short = align(req, { "错位甲", "错位乙" })
    Assert.is_nil(short[1], "短数组不能按顺序对齐")
    Assert.is_nil(short[2])
    Assert.is_nil(short[3])
    local ordered = align(req, { "你好", "世界", "福" })
    Assert.eq(ordered[1], "你好")
    Assert.eq(ordered[2], "世界")
    Assert.eq(ordered[3], "福")
    local skipped = align(req, { { id = 2, text = "世界" }, { id = 99, text = "x" } })
    Assert.is_nil(skipped[1])
    Assert.eq(skipped[2], "世界")
    Assert.is_nil(skipped[99], "请求里没有的 id 不能写入")
    local unknown = align(req, {
        { id = 98, text = "错误甲" }, { id = 99, text = "错误乙" }, { id = 100, text = "错误丙" },
    })
    Assert.is_nil(next(unknown), "对象编号全错也不能回退到顺序")
    local mixed = align(req, { "错误甲", false, "错误丙" })
    Assert.is_nil(next(mixed), "非法项不能删掉后按位置接到原文")
    local objects = align(req, { "错误甲", { id = 3, text = "福" }, "错误丙" })
    Assert.is_nil(objects[1])
    Assert.is_nil(objects[2])
    Assert.eq(objects[3], "福", "混合响应只能认显式匹配的对象编号")
    local blanks = align(req, { "  ", " 世界 ", "福" })
    Assert.is_nil(blanks[1])
    Assert.eq(blanks[2], "世界", "纯字符串空项仍占原位置")
end

-- AI 翻译：少返回时保留已译、只补缺的；完全没有可用译文才失败。
do
    local saved_ai = package.loaded["ai"]
    local saved_lang = package.loaded["features.translate.languages"]
    local saved_tr = package.loaded["ui/translator"]
    local replies, calls = {}, {}
    package.loaded["features.translate.languages"] = {
        displayName = function() return "Chinese (Simplified)" end,
    }
    package.loaded["ui/translator"] = {}
    package.loaded["ai"] = {
        jsonExtract = function(messages, _opts, cb)
            calls[#calls + 1] = require("support.json_stub").decode(messages[2].content).items
            local reply = table.remove(replies, 1)
            if reply == nil then
                cb(nil, "unexpected extra request")
            elseif reply.err and reply.items == nil then
                cb(nil, reply.err)
            else
                cb({ items = reply.items }, reply.err)
            end
            return { cancel = function() end }
        end,
    }

    -- 少返回且乱序：先留下已对齐的，第二次只补缺的，且不覆盖已成功的。
    replies = {
        { items = { { id = 3, text = "福" }, { id = 1, text = "你好" } } },
        { items = { { id = 1, text = "覆盖" }, { id = 2, text = "世界" } } },
    }
    calls = {}
    local got, err
    Bilingual.ENGINES.ai.translate({ "Hello", "World", "Foo" }, "zh", function(list, e)
        got, err = list, e
    end)
    Assert.is_nil(err)
    Assert.eq(got[1], "你好", "补缺不得覆盖已译")
    Assert.eq(got[2], "世界")
    Assert.eq(got[3], "福")
    Assert.len(calls, 2)
    Assert.len(calls[1], 3)
    Assert.len(calls[2], 1)
    Assert.eq(calls[2][1].id, 2)
    Assert.eq(calls[2][1].text, "World")

    -- 短数组不按顺序填入，整批再补一次。
    replies = {
        { items = { "错位甲", "错位乙" } },
        { items = { { id = 1, text = "你好" }, { id = 2, text = "世界" }, { id = 3, text = "福" } } },
    }
    calls = {}
    got, err = nil, nil
    Bilingual.ENGINES.ai.translate({ "Hello", "World", "Foo" }, "zh", function(list, e)
        got, err = list, e
    end)
    Assert.is_nil(err)
    Assert.eq(got[1], "你好")
    Assert.eq(got[2], "世界")
    Assert.eq(got[3], "福")
    Assert.len(calls, 2)
    Assert.len(calls[2], 3, "第一次对不上，补请求仍是全部")

    -- 第一次部分成功，补缺仍空：保留已译，不失败。
    replies = {
        { items = { { id = 1, text = "你好" } } },
        { items = {} },
    }
    calls = {}
    got, err = nil, nil
    Bilingual.ENGINES.ai.translate({ "Hello", "World" }, "zh", function(list, e)
        got, err = list, e
    end)
    Assert.is_nil(err)
    Assert.eq(got[1], "你好")
    Assert.is_nil(got[2])
    Assert.len(calls, 2)
    Assert.eq(calls[2][1].id, 2)

    -- 两次都没有可用译文才失败，不再抛内部英文错误。
    replies = {
        { items = { "only-one" } },
        { items = {} },
    }
    calls = {}
    got, err = nil, nil
    Bilingual.ENGINES.ai.translate({ "Hello", "World" }, "zh", function(list, e)
        got, err = list, e
    end)
    Assert.is_nil(got)
    Assert.eq(err, "AI 没有返回可用译文")

    -- 请求本身失败：把已有的中文错误传出去。
    replies = {
        { err = "AI 没有返回内容" },
        { err = "AI 没有返回内容" },
    }
    got, err = nil, nil
    Bilingual.ENGINES.ai.translate({ "Hello" }, "zh", function(list, e)
        got, err = list, e
    end)
    Assert.is_nil(got)
    Assert.eq(err, "AI 没有返回内容")

    -- 任务：部分成功仍生成双语版，未译段落不写入缓存，不把整页标失败。
    replies = {
        { items = { { id = 1, text = "章" }, { id = 2, text = "你好" } } },
        { items = {} },
    }
    local partial = input("ai_partial")
    partial.engine = "ai"
    local _hp, _rp, results_p = start(partial)
    Assert.is_true(results_p[1].ok)
    local body = read(partial.dest)
    has(body, ">章<")
    has(body, ">你好<")
    has(body, "<p>World</p>")
    Assert.is_true(body:find("World<br/>", 1, true) == nil, "World 未译不插入")
    local cache = read(partial.cache)
    has(cache, "[\"Chapter\",\"章\"]")
    has(cache, "[\"Hello\",\"你好\"]")
    Assert.is_true(cache:find("[\"World\"", 1, true) == nil, "未译不进缓存")

    -- 任务：完全没有可用译文才失败。
    replies = {
        { items = {} },
        { items = {} },
    }
    local none = input("ai_none")
    none.engine = "ai"
    local _hn, _rn, results_n = start(none)
    Assert.is_false(results_n[1].ok)
    Assert.eq(results_n[1].err, "AI 没有返回可用译文")
    Assert.is_nil(read(none.dest))

    package.loaded["ai"] = saved_ai
    package.loaded["features.translate.languages"] = saved_lang
    package.loaded["ui/translator"] = saved_tr
end

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
