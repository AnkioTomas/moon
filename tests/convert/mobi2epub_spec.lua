--[[--
MOBI 分页提取与 TXT 重排管线。

@module tests.convert.mobi2epub_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local current_doc
local current_provider
local built_opts
local build_calls
local cancelled_builds

package.preload["document/documentregistry"] = function()
    return {
        getProvider = function()
            return current_provider
        end,
        openDocument = function()
            return current_doc
        end,
    }
end

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end

package.preload["convert.text2epub"] = function()
    return {
        build = function(opts, cb)
            built_opts = opts
            build_calls = build_calls + 1
            local cancelled = false
            require("ui/uimanager"):nextTick(function()
                if not cancelled then
                    cb(true)
                end
            end)
            return {
                cancel = function()
                    cancelled = true
                    cancelled_builds = cancelled_builds + 1
                end,
            }
        end,
    }
end

local Mobi2Epub = require("convert.mobi2epub")

local function reset(doc, provider)
    current_doc = doc
    current_provider = provider or { provider = "crengine" }
    built_opts = nil
    build_calls = 0
    cancelled_builds = 0
end

local function run(doc, opts)
    reset(doc)
    local result, reason
    local job = Mobi2Epub.build(opts or {
        source = "/books/test.mobi",
        dest = "/tmp/reflow.epub",
    }, function(ok, err)
        result, reason = ok, err
    end)
    Stubs.flush()
    return result, reason, job
end

local function baseDoc(page_count)
    local doc = { close_count = 0, rendered = false }
    function doc:loadDocument()
        return true
    end
    function doc:render()
        self.rendered = true
    end
    function doc:getPageCount()
        return page_count
    end
    function doc:close()
        self.close_count = self.close_count + 1
    end
    return doc
end

-- 相邻页按顺序提取；只去掉完全重复的边界行；最终强制走 TXT 重排。
do
    local doc = baseDoc(3)
    local calls = {}
    function doc:getPageXPointer(page)
        calls[#calls + 1] = "xp:" .. page
        return "p" .. page
    end
    function doc:getTextFromXPointers(pos0, pos1)
        calls[#calls + 1] = pos0 .. ">" .. pos1
        if pos0 == "p1" then
            return "第一行\n重复行"
        end
        return "重复行\n第二行"
    end
    function doc:gotoPage(page)
        calls[#calls + 1] = "goto:" .. page
    end
    function doc:getTextFromPositions(pos0, pos1, no_draw)
        calls[#calls + 1] = string.format("screen:%d,%d:%s", pos1.x, pos1.y, tostring(no_draw))
        Assert.eq(pos0.x, 0)
        Assert.eq(pos0.y, 0)
        return { text = "第三行" }
    end

    local progress = {}
    local ok, err = run(doc, {
        source = "/books/test.mobi",
        dest = "/tmp/reflow.epub",
        title = "测试",
        author = "作者",
        identifier = "book-id",
        on_progress = function(ev)
            if ev.phase == "extract" then
                progress[#progress + 1] = ev.index
            end
        end,
    })

    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.is_true(doc.rendered)
    Assert.eq(doc.close_count, 1)
    Assert.eq(build_calls, 1)
    Assert.eq(built_opts.text, "第一行\n重复行\n第二行\n第三行")
    Assert.is_true(built_opts.reflow)
    Assert.eq(built_opts.source, "/books/test.mobi")
    Assert.eq(built_opts.title, "测试")
    Assert.eq(built_opts.author, "作者")
    Assert.eq(built_opts.identifier, "book-id")
    Assert.eq(table.concat(progress, ","), "1,2,3")
    Assert.eq(table.concat(calls, ","),
        "xp:1,xp:2,p1>p2,xp:2,xp:3,p2>p3,goto:3,screen:600,800:true")
end

-- provider 不是 CRengine 时直接拒绝，不打开文档。
do
    local doc = baseDoc(1)
    reset(doc, { provider = "other" })
    local ok, err
    Mobi2Epub.build({ source = "/books/test.mobi", dest = "/tmp/x.epub" }, function(value, reason)
        ok, err = value, reason
    end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "此 MOBI 无法由 CRengine 打开")
    Assert.eq(doc.close_count, 0)
    Assert.eq(build_calls, 0)
end

-- loadDocument 失败后也必须关闭已经打开的文档。
do
    local doc = baseDoc(1)
    function doc:loadDocument()
        return false
    end
    local ok, err = run(doc)
    Assert.is_nil(ok)
    Assert.eq(err, "无法读取 MOBI")
    Assert.eq(doc.close_count, 1)
    Assert.eq(build_calls, 0)
end

-- render 抛错不能泄漏 CRengine 文档。
do
    local doc = baseDoc(1)
    function doc:render()
        error("broken render")
    end
    local ok, err = run(doc)
    Assert.is_nil(ok)
    Assert.matches(err, "无法读取 MOBI")
    Assert.eq(doc.close_count, 1)
    Assert.eq(build_calls, 0)
end

-- 空页数和空正文都不进入 EPUB 构建。
do
    local doc = baseDoc(0)
    local ok, err = run(doc)
    Assert.is_nil(ok)
    Assert.eq(err, "MOBI 没有可提取的文本")
    Assert.eq(doc.close_count, 1)
    Assert.eq(build_calls, 0)

    doc = baseDoc(1)
    function doc:gotoPage() end
    function doc:getTextFromPositions()
        return { text = "\n\n" }
    end
    ok, err = run(doc)
    Assert.is_nil(ok)
    Assert.eq(err, "MOBI 没有可提取的文本")
    Assert.eq(doc.close_count, 1)
    Assert.eq(build_calls, 0)
end

-- 每页单独 nextTick；打开后取消会立即 close，排队的页不再提取也不回调。
do
    local UIManager = require("ui/uimanager")
    local original_next_tick = UIManager.nextTick
    local pending = {}
    UIManager.nextTick = function(_, fn)
        pending[#pending + 1] = fn
    end
    local function tick()
        local fn = table.remove(pending, 1)
        Assert.not_nil(fn)
        fn()
    end

    local doc = baseDoc(2)
    local extracted = 0
    function doc:getPageXPointer(page) return "p" .. page end
    function doc:getTextFromXPointers()
        extracted = extracted + 1
        return "正文"
    end
    function doc:gotoPage() end
    function doc:getTextFromPositions() return { text = "结尾" } end

    reset(doc)
    local callbacks = 0
    local job = Mobi2Epub.build({ source = "/books/test.mobi", dest = "/tmp/x.epub" }, function()
        callbacks = callbacks + 1
    end)
    Assert.eq(#pending, 1)
    tick() -- open + render，只排入第一页
    Assert.eq(#pending, 1)
    Assert.eq(extracted, 0)
    job.cancel()
    Assert.eq(doc.close_count, 1)
    tick() -- 已排队的第一页看到 cancelled 后退出
    Assert.eq(extracted, 0)
    Assert.eq(callbacks, 0)
    Assert.eq(build_calls, 0)
    Assert.eq(#pending, 0)

    UIManager.nextTick = original_next_tick
end

