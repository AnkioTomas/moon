--[[--
MOBI 分页提取。

@module tests.features.reflow.mobi_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()

local current_doc
local current_provider

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

local Mobi = require("features.reflow.mobi")

local function reset(doc, provider)
    current_doc = doc
    current_provider = provider or { provider = "crengine" }
end

local function run(doc)
    reset(doc)
    local result, reason
    local job = Mobi.extract("/books/test.mobi", function(text, err)
        result, reason = text, err
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

-- 相邻页按顺序提取；只去掉完全重复的边界行。
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

    local text, err = run(doc)

    Assert.eq(text, "第一行\n重复行\n第二行\n第三行")
    Assert.is_nil(err)
    Assert.is_true(doc.rendered)
    Assert.eq(doc.close_count, 1)
    Assert.eq(table.concat(calls, ","),
        "xp:1,xp:2,p1>p2,xp:2,xp:3,p2>p3,goto:3,screen:600,800:true")
end

-- provider 不是 CRengine 时直接拒绝，不打开文档。
do
    local doc = baseDoc(1)
    reset(doc, { provider = "other" })
    local ok, err
    Mobi.extract("/books/test.mobi", function(value, reason)
        ok, err = value, reason
    end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "此 MOBI 无法由 CRengine 打开")
    Assert.eq(doc.close_count, 0)
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
end

-- 空页数和空正文都算失败。
do
    local doc = baseDoc(0)
    local ok, err = run(doc)
    Assert.is_nil(ok)
    Assert.eq(err, "MOBI 没有可提取的文本")
    Assert.eq(doc.close_count, 1)

    doc = baseDoc(1)
    function doc:gotoPage() end
    function doc:getTextFromPositions()
        return { text = "\n\n" }
    end
    ok, err = run(doc)
    Assert.is_nil(ok)
    Assert.eq(err, "MOBI 没有可提取的文本")
    Assert.eq(doc.close_count, 1)
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
    local job = Mobi.extract("/books/test.mobi", function()
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
    Assert.eq(#pending, 0)

    UIManager.nextTick = original_next_tick
end

