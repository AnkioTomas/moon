--[[--
session.auto_toc 离线用例：整书无目录时扫描章节标题并装入自定义目录。

@module tests.ui.reader.auto_toc_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
local shown = {}
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) shown[#shown + 1] = o; return o end }
end
local jobs = {}
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            local job = { opts = opts, cancelled = false }
            function job:cancel() self.cancelled = true end
            jobs[#jobs + 1] = job
            job.result = worker()
            return job
        end,
    }
end

local AutoToc = require("ui.reader.session.auto_toc")

--- 模拟 CRE 文档：lines[i] 是第 i 个段落的文本节点。
local function mkDocument(lines)
    return {
        findAllText = function(_, pattern, case_insensitive, _ctx, _max, regex)
            Assert.is_true(case_insensitive)
            Assert.is_true(regex)
            Assert.matches(pattern, "章回节")
            local hits = {}
            for i, line in ipairs(lines) do
                if line:find("第", 1, true) or line:lower():find("chapter", 1, true)
                    or line:find("前言", 1, true) then
                    -- 同一节点命中两次必须去重
                    hits[#hits + 1] = { start = "/body/p[" .. i .. "]/text().0" }
                    hits[#hits + 1] = { start = "/body/p[" .. i .. "]/text().3" }
                end
            end
            return #hits > 0 and hits or nil
        end,
        getTextFromXPointer = function(_, xp)
            return lines[tonumber(xp:match("p%[(%d+)%]"))]
        end,
        getPageFromXPointer = function(_, xp)
            return tonumber(xp:match("p%[(%d+)%]")) * 10
        end,
    }
end

local function mkSession(lines, opts)
    opts = opts or {}
    local settings = { moon_auto_toc = opts.scanned }
    local footer_updates = 0
    local ui = {
        rolling = not opts.paging and {} or nil,
        document = mkDocument(lines),
        doc_settings = {
            isTrue = function(_, key) return settings[key] == true end,
            saveSetting = function(_, key, value) settings[key] = value end,
        },
        view = { footer = { maybeUpdateFooter = function() footer_updates = footer_updates + 1 end } },
        toc = { toc = opts.toc },
    }
    ui.handmade = {
        toc = {},
        toc_enabled = opts.handmade == true,
        isHandmadeTocEnabled = function(self) return self.toc_enabled end,
        setupToc = function(self) self.setup_calls = (self.setup_calls or 0) + 1 end,
    }
    return { ui = ui }, settings, function() return footer_updates end
end

local BOOK = {
    "前言",
    "这里是前言正文。",
    "第一章 开端",
    "第一天，他出门了。第二天他回来了，这一段话足够长，长到不会被当成章节标题，因为正文段落总是会写很多很多很多很多很多很多很多很多字。",
    "第二章 转折",
    "第三章我们讲过的事情，这一行虽然以第三章开头，但它是正文，而且长度超过了标题行的上限，所以必须被过滤掉才行，否则目录会乱七八糟的。",
    "Chapter 3 The End",
}

-- 正常路径：无目录 → 扫描 → 装入自定义目录，过滤正文、节点去重、页码按 xpointer 重算
do
    shown = {}
    local session, settings, footer = mkSession(BOOK)
    AutoToc.start(session)
    Assert.len(jobs, 1)
    Assert.eq(jobs[1].opts.kind, "medium")
    jobs[1].opts.on_done(jobs[1].result)

    local handmade = session.ui.handmade
    Assert.is_true(handmade.toc_enabled)
    Assert.eq(handmade.setup_calls, 1)
    Assert.eq(footer(), 1)
    Assert.len(handmade.toc, 4)
    Assert.eq(handmade.toc[1].title, "前言")
    Assert.eq(handmade.toc[2].title, "第一章 开端")
    Assert.eq(handmade.toc[2].xpointer, "/body/p[3]/text().0")
    Assert.eq(handmade.toc[2].page, 30)
    Assert.eq(handmade.toc[2].depth, 1)
    Assert.eq(handmade.toc[3].title, "第二章 转折")
    Assert.eq(handmade.toc[4].title, "Chapter 3 The End")
    Assert.is_true(settings.moon_auto_toc)
    Assert.is_nil(session.auto_toc_job)
    Assert.len(shown, 1)
end

-- 已扫描过 / 已有自定义目录 / 文档自带目录 ≥2 / 分页文档：都不扫描
do
    jobs = {}
    AutoToc.start((mkSession(BOOK, { scanned = true })))
    AutoToc.start((mkSession(BOOK, { handmade = true })))
    AutoToc.start((mkSession(BOOK, { toc = { { title = "一", page = 1 }, { title = "二", page = 5 } } })))
    AutoToc.start((mkSession(BOOK, { paging = true })))
    Assert.len(jobs, 0)
end

-- 文档自带目录只有一项：仍然扫描
do
    jobs = {}
    AutoToc.start((mkSession(BOOK, { toc = { { title = "书名", page = 1 } } })))
    Assert.len(jobs, 1)
end

-- 识别不到两章：只记已扫描，不动目录
do
    jobs, shown = {}, {}
    local session, settings = mkSession({ "第一章 唯一", "正文。" })
    AutoToc.start(session)
    jobs[1].opts.on_done(jobs[1].result)
    Assert.is_false(session.ui.handmade.toc_enabled)
    Assert.is_true(settings.moon_auto_toc)
    Assert.len(shown, 0)

    jobs = {}
    session, settings = mkSession({ "没有任何章节。" })
    AutoToc.start(session)
    Assert.len(jobs[1].result, 0)
end

-- 扫描失败不记已扫描（下次开书重试）；关书取消在飞任务
do
    jobs = {}
    local session, settings = mkSession(BOOK)
    AutoToc.start(session)
    jobs[1].opts.on_failed("boom")
    Assert.is_nil(settings.moon_auto_toc)
    Assert.is_nil(session.auto_toc_job)

    jobs = {}
    session = mkSession(BOOK)
    AutoToc.start(session)
    local job = session.auto_toc_job
    AutoToc.stop(session)
    Assert.is_true(job.cancelled)
    Assert.is_nil(session.auto_toc_job)
    AutoToc.stop(nil)
end
