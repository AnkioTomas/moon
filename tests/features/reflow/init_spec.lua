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
package.preload["features.reflow.extract"] = function()
    return {
        run = function(ui, cb)
            extracted_ui = ui
            cb("第一章 开始\n正文\n第二章 继续\n更多")
            return { cancel = function() end }
        end,
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

-- 目录标题
local titles = Reflow._tocTitles(Text2Epub.parse("第一章 开始\n正文\n\n第二章 继续\n更多", { title = "测试", reflow = true }).chapters)
Assert.eq(table.concat(titles, "|"), "第一章 开始|第二章 继续")

-- TXT：子进程读文件、识别章节，只传回目录标题
local txt = os.tmpname() .. ".txt"
local f = io.open(txt, "w")
f:write("第一章 开始\n正文\n\n第二章 继续\n更多")
f:close()
local preview, err
local steps = {}
local function progress(text, done, total) steps[#steps + 1] = text .. " " .. done .. "/" .. total end
Reflow.analyzeAsync(reader(txt, "rolling"), identity, function(p, e) preview, err = p, e end, progress)
Assert.is_nil(preview, "识别在子进程里，不在调用栈上同步完成")
Stubs.flush()
Assert.is_nil(err)
Assert.eq(jobs[#jobs].name, "epub.chapters")
Assert.is_nil(preview.text, "TXT 全文不进主进程，生成时子进程重读原文件")
Assert.eq(table.concat(preview.titles, "|"), "第一章 开始|第二章 继续")
Assert.is_nil(extracted_ui, "TXT 不走逐页提取")
Assert.eq(table.concat(steps, ","), "正在识别章节 1/2,正在识别章节 2/2", "子进程按节报进度")

f = io.open(txt, "wb")
f:write("\255\254bad")
f:close()
Reflow.analyzeAsync(reader(txt, "rolling"), identity, function(p, e) preview, err = p, e end, progress)
Stubs.flush()
Assert.is_nil(preview)
Assert.not_nil(err)

-- 其它格式：从打开的文档逐页提取
local pdf_ui = reader("/books/a.pdf", "pdf")
Reflow.analyzeAsync(pdf_ui, identity, function(p, e) preview, err = p, e end, progress)
Stubs.flush()
Assert.eq(extracted_ui, pdf_ui)
Assert.eq(preview.text, "第一章 开始\n正文\n第二章 继续\n更多", "预览持有提取的全文，确认后原样交给转换")
Assert.len(preview.titles, 2)

-- 原文档带目录：标题整行命中即切章（不是「第 X 章」写法也认），开头的内嵌目录不切出空章
toc_titles = { "（1970）双剑交锋（1）", "（1971）亮出底牌（1）" }
local toc_txt = os.tmpname() .. ".txt"
f = io.open(toc_txt, "wb")
f:write("目录\n（1970）双剑交锋（1）\n（1971）亮出底牌（1）\n（1970）双剑交锋（1）\n春天。\n（1971）亮出底牌（1）\n北戴河。")
f:close()
Reflow.analyzeAsync(reader(toc_txt, "rolling"), identity, function(p, e) preview, err = p, e end, progress)
Stubs.flush()
Assert.eq(table.concat(preview.titles, "|"), "（1970）双剑交锋（1）|（1971）亮出底牌（1）")
Assert.eq(table.concat(preview.headings, "|"), "（1970）双剑交锋（1）|（1971）亮出底牌（1）")
toc_titles = {}
os.remove(toc_txt)

-- 生成：EPUB 和 meta 都在工作目录 reflow/ 下，原书不动
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
local path
sidecars[dir .. "/book.epub"] = { annotations = { { pos0 = "/body/old" } }, book_note_linked = { a = true } }
Reflow.applyAsync(identity, txt, { text = "全文", headings = { "甲" }, titles = {} }, function(p, e) path, err = p, e end)
Assert.is_nil(err)
Assert.eq(path, dir .. "/book.epub")
Assert.is_nil(sidecars[path].annotations, "重新排版同一路径：旧划线坐标指向旧结构，清掉")
Assert.is_nil(sidecars[path].book_note_linked)
Assert.eq(built.text, "全文")
Assert.eq(built.headings[1], "甲", "原文档目录标题带到转换")
Assert.eq(built.source, txt, "书名 / 作者仍可从原书文件名推断")
Assert.is_true(built.reflow)
local meta = require("support.json_stub").decode(assert(io.open(dir .. "/meta.json")):read("*a"))
Assert.eq(meta.origin, txt)
Assert.eq(meta.file, dir .. "/book.epub")
Assert.eq(assert(io.open(txt, "rb")):read("*a"), "\255\254bad", "原书原样保留")

-- 生成失败：回调错误，meta 不变
Text2Epub.build = function(opts, cb) cb(nil, "磁盘满") return { cancel = function() end } end
Reflow.applyAsync(identity, "/books/other.epub", { text = "全文", headings = {}, titles = {} }, function(p, e) path, err = p, e end)
Assert.is_nil(path)
Assert.eq(err, "磁盘满")
meta = require("support.json_stub").decode(assert(io.open(dir .. "/meta.json")):read("*a"))
Assert.eq(meta.origin, txt)
Text2Epub.build = original_build

-- 读原书、已有排版版：面板给出「打开排版版 / 重新排版」，打开时按比例落位、搬排版
local origin_ui = reader(txt, "rolling")
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
Assert.eq(touched.path, dir .. "/book.epub")
Assert.eq(touched.identity, identity)
Assert.eq(switched, dir .. "/book.epub")

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

-- 没有排版版：TXT 直接分析，其它格式先确认有损
require("ffi/util").purgeDir(dir)
local shown_before = #Themed.made
Reflow.show(reader("/books/a.epub", "rolling"))
Assert.eq(Themed.last("confirm").ok_text, "继续")
Assert.matches(Themed.last("confirm").text, "原书保留不变")
Assert.is_true(#Themed.made > shown_before)

-- 分析进度窗：任务同款，不能取消也不能转后台、返回键不关；显示步骤与进度，结果回来自动关
local fresh_txt = os.tmpname() .. ".txt"
f = assert(io.open(fresh_txt, "wb"))
f:write("第一章 开始\n正文\n\n第二章 继续\n更多")
f:close()
Reflow.show(reader(fresh_txt, "rolling"))
local dialog = Themed.last("progress_dialog")
Assert.is_true(dialog.shown)
Assert.eq(dialog.title, "优化排版")
Assert.is_false(dialog.dismissable)
Assert.is_nil(dialog.on_cancel)
Assert.is_nil(dialog.on_background)
Stubs.flush()
Assert.eq(dialog.updates[1][1], "正在识别章节")
Assert.eq(dialog.updates[#dialog.updates][2], 2)
Assert.eq(dialog.updates[#dialog.updates][3], 2)
Assert.is_true(dialog.closed)
Assert.eq(Themed.last("list").title, "排版预览")
os.remove(fresh_txt)

os.remove(txt)
os.remove(txt .. ".pdf")
