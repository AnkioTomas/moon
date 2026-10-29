--[[-- features.reflow：可用性、分析、生成到工作目录（原书不动）、两版切换。 --]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function() return require("support.json_stub") end
local Themed = require("support.theme_stubs")
Themed.install()

local session
package.preload["reader.session"] = function()
    return { current = function() return session end }
end
local extracted_ui
local extract_tmp
package.preload["features.reflow.extract"] = function()
    return {
        run = function(ui, cb, on_progress)
            extracted_ui = ui
            extract_tmp = os.tmpname() .. ".txt"
            local f = assert(io.open(extract_tmp, "wb"))
            f:write("第一章 开始\n正文\n第二章 继续\n更多")
            f:close()
            if on_progress then on_progress("extract", 1, 1) end
            cb(extract_tmp)
            return { cancel = function() end }
        end,
        -- 成功收尾清断点：测试里的临时正文一并删掉，对齐工作目录 extract.txt 被清掉的行为。
        clearCheckpoint = function()
            if extract_tmp then os.remove(extract_tmp) end
        end,
        hasCheckpoint = function() return false end,
        donePath = function() return nil end,
        donePages = function() return 0 end,
        canDumpDom = function() return false end,
    }
end
local sidecars = {}
package.preload["docsettings"] = function()
    return {
        open = function(_, path)
            local data = sidecars[path] or {}
            sidecars[path] = data
            return {
                readSetting = function(_, key) return data[key] end,
                saveSetting = function(_, key, value) data[key] = value end,
                delSetting = function(_, key) data[key] = nil end,
                flush = function() data.flushed = true end,
                purge = function() for key in pairs(data) do data[key] = nil end end,
            }
        end,
    }
end
local touched
package.preload["book.store"] = function()
    return { touch = function(path, identity) touched = { path = path, identity = identity } return true end }
end
local prefs_written
package.preload["reader.prefs"] = function()
    return {
        capture = function(ui) return ui.rolling and { copt = { font_size = 22 } } or nil end,
        write = function(settings, prefs) prefs_written = prefs end,
    }
end
package.preload["document/documentregistry"] = function()
    return {
        getProvider = function(_, path)
            return { provider = path:match("%.pdf$") and "mupdf" or "crengine" }
        end,
    }
end

-- 子进程替身：下一 tick 执行，进度与结果按管道协议过一遍 JSON（子进程只能传回可序列化的值）
local jobs = {}
package.preload["workers.job"] = function()
    local JSON = require("json")
    return {
        run = function(worker, opts)
            local job = { name = opts.name }
            function job:cancel() self.cancelled = true end
            jobs[#jobs + 1] = job
            require("ui/uimanager"):nextTick(function()
                if job.cancelled then return end
                local result = worker(function(value)
                    if opts.on_progress then opts.on_progress(JSON.decode(JSON.encode(value))) end
                end)
                opts.on_done(JSON.decode(JSON.encode(result)))
            end)
            return job
        end,
    }
end

local started, followed, running
package.preload["workers.ui.task_dialog"] = function()
    return { start = function(spec) started = spec end, follow = function(task) followed = task end }
end
package.preload["workers.tasks"] = function()
    return { get = function(key) return running and running.key == key and running or nil end }
end
local reader_instance = {}
package.preload["apps/reader/readerui"] = function() return reader_instance end

local Reflow = require("features.reflow")
local Text2Epub = require("convert.text2epub")
local Paths = require("utils.paths")

local source = { id = "local" }
local identity = {
    source_id = "local", stable_id = "/books/reflow-spec.txt", source = source,
    book = { title = "测试", authors = "作者" },
}
session = { identity = identity, fraction = 0.4 }
local dir = Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/reflow"
require("ffi/util").purgeDir(dir)

local switched
local toc_titles = {}
local function reader(file, kind)
    local ui = {
        document = { file = file },
        switchDocument = function(_, target) switched = target end,
        toc = { fillToc = function(self)
            self.toc = {}
            for i, title in ipairs(toc_titles) do self.toc[i] = { title = title, page = i } end
        end },
    }
    if kind == "rolling" then ui.rolling = {} end
    if kind == "pdf" then ui.paging = {}; ui.document.getPageTextBoxes = function() end end
    return ui
end

-- 可用性：整本书的流式文档、带文字层的固定版式；章节源、纯图片、没有会话都不行
Assert.is_true(Reflow.available(reader("/books/a.epub", "rolling")))
Assert.is_true(Reflow.available(reader("/books/a.pdf", "pdf")))
Assert.is_false(Reflow.available(reader("/books/a.cbz", "image")), "没有文字层接口")
source.type = "chapter"
Assert.is_false(Reflow.available(reader("/books/a.epub", "rolling")), "章节源不做")
source.type = nil
session = nil
Assert.is_false(Reflow.available(reader("/books/a.epub", "rolling")))
session = { identity = identity, fraction = 0.4 }

-- 生成：TXT 子进程读原文件；EPUB 和 meta 都在工作目录 reflow/ 下，原书不动
local txt = os.tmpname() .. ".txt"
local f = io.open(txt, "w")
f:write("第一章 开始\n正文\n\n第二章 继续\n更多")
f:close()
local original_build = Text2Epub.build
local built
Text2Epub.build = function(opts, cb)
    built = opts
    local out = assert(io.open(opts.dest, "wb"))
    out:write("epub")
    out:close()
    cb(true)
    return { cancel = function() end }
end
local path, err
sidecars[dir .. "/book.epub"] = { annotations = { { pos0 = "/body/old" } }, book_note_linked = { a = true } }
toc_titles = { "甲" }
Reflow.runAsync(reader(txt, "rolling"), identity, function(p, e) path, err = p, e end, function() end)
toc_titles = {}
Assert.is_nil(err)
Assert.eq(path, dir .. "/book.epub")
Assert.is_nil(extracted_ui, "TXT 不走逐页提取")
Assert.is_nil(built.text, "TXT 全文不进主进程，子进程读原文件")
Assert.is_nil(sidecars[path].annotations, "重新排版同一路径：旧划线坐标指向旧结构，清掉")
Assert.is_nil(sidecars[path].book_note_linked)
Assert.eq(built.headings[1], "甲", "原文档目录标题带到转换")
Assert.eq(built.source, txt, "书名 / 作者仍可从原书文件名推断")
Assert.is_true(built.reflow)
local meta = require("support.json_stub").decode(assert(io.open(dir .. "/meta.json")):read("*a"))
Assert.eq(meta.origin, txt)
Assert.eq(meta.file, dir .. "/book.epub")

-- 其它格式：先从打开的文档逐页取字落盘，再交给转换（主进程不持有全文）
local pdf_ui = reader("/books/a.pdf", "pdf")
Reflow.runAsync(pdf_ui, identity, function(p, e) path, err = p, e end, function() end)
Assert.eq(extracted_ui, pdf_ui)
Assert.is_nil(built.text, "全文不进主进程")
Assert.eq(built.text_file, extract_tmp)
Assert.is_nil(io.open(extract_tmp), "转换结束后删临时文件")
Reflow.runAsync(reader(txt, "rolling"), identity, function(p, e) path, err = p, e end, function() end)

-- 生成失败：回调错误，meta 不变
Text2Epub.build = function(opts, cb) cb(nil, "磁盘满") return { cancel = function() end } end
Reflow.runAsync(reader("/books/other.txt", "rolling"), identity, function(p, e) path, err = p, e end, function() end)
Assert.is_nil(path)
Assert.eq(err, "磁盘满")
meta = require("support.json_stub").decode(assert(io.open(dir .. "/meta.json")):read("*a"))
Assert.eq(meta.origin, txt, "失败不改 meta")
-- 取消：杀子进程、删半截 .part，已有排版版与 meta 不动
local build_cancelled
Text2Epub.build = function(opts, cb)
    local out = assert(io.open(opts.dest .. ".part", "wb"))
    out:write("half")
    out:close()
    return { cancel = function() build_cancelled = true end }
end
path, err = nil, nil
local handle = Reflow.runAsync(reader(txt, "rolling"), identity, function(p, e) path, err = p, e end, function() end)
handle.cancel()
Assert.is_true(build_cancelled)
Assert.is_nil(io.open(dir .. "/book.epub.part"))
Assert.eq(assert(io.open(dir .. "/book.epub", "rb")):read("*a"), "epub", "旧排版版不受影响")
Assert.is_nil(path)
-- 取字中取消：不再进入转换；晚到的路径回调只删临时文件
local extract_cb
package.loaded["features.reflow.extract"] = {
    run = function(ui, cb) extract_cb = cb return { cancel = function() end } end,
    donePages = function() return 0 end,
    clearCheckpoint = function() end,
    hasCheckpoint = function() return false end,
    donePath = function() return nil end,
    canDumpDom = function() return false end,
}
built = nil
Text2Epub.build = function(opts, cb) built = opts return { cancel = function() end } end
handle = Reflow.runAsync(reader("/books/a.epub", "rolling"), identity, function(p, e) path, err = p, e end, function() end)
handle.cancel()
local late = os.tmpname() .. ".txt"
local late_file = assert(io.open(late, "wb"))
late_file:write("全文")
late_file:close()
extract_cb(late)
Assert.is_nil(built, "取消后不再打包")
Assert.is_nil(io.open(late), "取消后丢掉晚到的提取文件")
package.loaded["features.reflow.extract"] = nil
Text2Epub.build = original_build

-- 读原书、已有排版版：面板给出「打开排版版 / 重新排版」，打开时按比例落位、搬排版
local origin_ui = reader(txt, "rolling")
local remembered = {}
origin_ui.doc_settings = { saveSetting = function(_, key, value) remembered[key] = value end }
Assert.is_false(Reflow.active(origin_ui))
sidecars[dir .. "/book.epub"] = { last_xpointer = "/body/old", doc_pages = 200 }
Reflow.show(origin_ui)
local sheet = Themed.last("sheet")
Assert.eq(sheet.items[1].text, "打开排版版")
Assert.eq(sheet.items[2].text, "重新排版")
sheet.items[1].callback()
local target = sidecars[dir .. "/book.epub"]
Assert.is_nil(target.last_xpointer, "两版 xpointer 不通用")
Assert.eq(target.last_percent, 0.4)
Assert.eq(target.last_page, 80)
Assert.is_true(target.flushed)
Assert.eq(prefs_written.copt.font_size, 22)
Assert.eq(remembered.book_last_derived, dir .. "/book.epub", "上次读的版本记在原书 sidecar")
Assert.is_nil(touched, "books.path 不动")
Assert.eq(switched, dir .. "/book.epub")

-- 两边都是 CREngine：记下当前页开头文字，目标打开后按文字落位（搜不到保留比例落点）
do
    local ui = reader(txt, "rolling")
    ui.rolling = { current_page = 3 }
    ui.document.getPageCount = function() return 10 end
    ui.document.getPageXPointer = function(_, page) return "xp" .. page end
    ui.document.getTextFromXPointers = function(_, from) return from == "xp3" and "  第三页的开头文字很长很长很长很长\n后面" or "" end
    sidecars[dir .. "/book.epub"] = {}
    local epub = assert(io.open(dir .. "/book.epub", "wb"))
    epub:write("epub")
    epub:close()
    ui.doc_settings = { saveSetting = function() end }
    Reflow.show(ui)
    Assert.eq(Themed.last("sheet").items[1].text, "打开排版版")
    Themed.last("sheet").items[1].callback()
    Assert.eq(switched, dir .. "/book.epub")
    local anchor = sidecars[dir .. "/book.epub"].moon_reflow_anchor
    Assert.eq(anchor.text, "第三页的开头文字很长很长很长很长")
    Assert.eq(anchor.fraction, 0.4)

    local located, goto_xp
    local DerivedNote = require("reader.session.derived_note")
    local original_locate = DerivedNote.locate
    DerivedNote.locate = function(_, text, fraction) located = { text, fraction } return "/body/hit" end
    package.preload["ui/event"] = function()
        return { new = function(_, name, xp) return { name = name, xp = xp } end }
    end
    local settings = sidecars[dir .. "/book.epub"]
    local target_ui = {
        rolling = {}, document = {},
        doc_settings = {
            readSetting = function(_, key) return settings[key] end,
            delSetting = function(_, key) settings[key] = nil end,
        },
        handleEvent = function(_, event) goto_xp = event end,
    }
    Reflow.onReaderReady({ ui = target_ui })
    Stubs.flush()
    Assert.eq(located[1], anchor.text)
    Assert.eq(goto_xp.xp, "/body/hit")
    Assert.is_nil(settings.moon_reflow_anchor, "锚点用一次就清")
    DerivedNote.locate = original_locate
end

-- 读排版版：面板高亮，点一下直接切回原书；原书不是 CREngine 时不搬排版
local reflowed_ui = reader(dir .. "/book.epub", "rolling")
Assert.is_true(Reflow.active(reflowed_ui))
local pdf_meta = assert(io.open(dir .. "/meta.json", "wb"))
pdf_meta:write(require("support.json_stub").encode({ origin = txt .. ".pdf", file = dir .. "/book.epub" }))
pdf_meta:close()
local pdf_origin = assert(io.open(txt .. ".pdf", "wb"))
pdf_origin:write("pdf")
pdf_origin:close()
prefs_written, switched = nil, nil
session.fraction = 0.5
Reflow.show(reflowed_ui)
Assert.eq(switched, txt .. ".pdf")
Assert.is_nil(prefs_written, "copt_ 在 PDF sidecar 里是 KOPT 设置")
Assert.eq(sidecars[txt .. ".pdf"].last_percent, 0.5)

-- 读别的衍生版（双语版）时不能再套一层排版：二级衍生版的划线收不回笔记库
local bilingual_dir = Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/bilingual"
assert(Paths.ensureDir(bilingual_dir))
local bilingual_meta = assert(io.open(bilingual_dir .. "/meta.json", "wb"))
bilingual_meta:write(require("support.json_stub").encode({ origin = txt, file = bilingual_dir .. "/book.epub" }))
bilingual_meta:close()
Assert.is_false(Reflow.available(reader(bilingual_dir .. "/book.epub", "rolling")))
Assert.is_true(Reflow.available(reflowed_ui), "读自己的排版版仍可用（切回原书）")
require("ffi/util").purgeDir(bilingual_dir)

-- 没有排版版：TXT 直接分析，其它格式先确认有损，并带预计耗时
require("ffi/util").purgeDir(dir)
local shown_before = #Themed.made
local epub_ui = reader("/books/a.epub", "rolling")
epub_ui.document.getPageCount = function() return 600 end
Reflow.show(epub_ui)
Assert.eq(Themed.last("confirm").ok_text, "继续")
Assert.matches(Themed.last("confirm").text, "原书保留不变")
Assert.matches(Themed.last("confirm").text, "预计需要")
Assert.matches(Themed.last("confirm").text, "约 %d+ 分钟")
Assert.is_true(#Themed.made > shown_before)

-- 耗时估算：DOM 路径是固定底；逐页路径按剩余页数
Assert.eq(Reflow.formatEta(30), "约 1 分钟")
Assert.eq(Reflow.formatEta(90), "约 2 分钟")
Assert.eq(Reflow.formatEta(3600), "约 1 小时 0 分")
local dom_ui = reader("/books/big.epub", "rolling")
dom_ui.document.getPageCount = function() return 12000 end
dom_ui.document.getHTMLFromXPointer = function() return "<p>x</p>" end
package.loaded["features.reflow.extract"].canDumpDom = function() return true end
local dom_sec = Reflow.estimateSeconds(dom_ui, identity, true)
Assert.is_true(dom_sec < 300, "DOM 倒出不应再按万页估")
Assert.is_true(dom_sec > 90, "仍含转 EPUB 底")
package.loaded["features.reflow.extract"].canDumpDom = function() return false end
local page_ui = reader("/books/scan.pdf", "pdf")
page_ui.document.getPageCount = function() return 12000 end
local full = Reflow.estimateSeconds(page_ui, identity, true)
Assert.is_true(full > 90, "固定版式取字仍按页估")
package.loaded["features.reflow.extract"].donePages = function() return 11000 end
local resume_sec = Reflow.estimateSeconds(page_ui, identity, false)
Assert.is_true(resume_sec < full, "续跑应明显短于整本重来")
package.loaded["features.reflow.extract"].donePages = function() return 0 end
package.loaded["features.reflow.extract"].canDumpDom = function() return false end

-- 整个排版是一个后台任务（每本书一个 key，可取消、可转后台），不再弹预览
local fresh_txt = os.tmpname() .. ".txt"
f = assert(io.open(fresh_txt, "wb"))
f:write("第一章 开始\n正文\n\n第二章 继续\n更多")
f:close()
local fresh_ui = reader(fresh_txt, "rolling")
Reflow.show(fresh_ui)
Assert.eq(started.key, "reflow\0local\0" .. identity.stable_id)
Assert.eq(started.kind, "convert")
Assert.eq(started.title, "测试（排版）")
Assert.is_true(started.restartable)
local result
Text2Epub.build = function(opts, cb) cb(true) return { cancel = function() end } end
local task_handle = started.run(function() end, function(r) result = r end)
Text2Epub.build = original_build
Assert.not_nil(task_handle.cancel)
Assert.is_true(result.ok)
Assert.eq(result.file, dir .. "/book.epub")
-- 完成：书已关只提示；还在读原书询问打开；失败提示原因
started.on_done(result)
Assert.eq(Themed.last("toast").text, "排版版已生成")
reader_instance.instance = fresh_ui
started.on_done(result)
Assert.eq(Themed.last("confirm").text, "排版版已生成，现在打开？")
started.on_done({ ok = false, err = "磁盘满\nstack" })
Assert.eq(Themed.last("toast").text, "磁盘满")

-- 重复：生成中再点入口只跟随进度，不重新分析
running = { key = started.key }
local lists = #Themed.made
Reflow.show(fresh_ui)
Assert.eq(followed, running)
Assert.eq(#Themed.made, lists)
running = nil
os.remove(fresh_txt)

os.remove(txt)
os.remove(txt .. ".pdf")
