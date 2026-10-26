--[[--
从打开的文档逐页取文字：流式 / 固定版式、出错、空文本、取消、中途关书。

@module tests.features.reflow.extract_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
end
-- 假时钟（毫秒）：每页耗时由用例的 doc.cost 决定，分批可预测
local clock = 0
package.preload["utils.perf"] = function() return { now = function() return clock end } end

local Extract = require("features.reflow.extract")

local function ignore() end

--- 读出提取结果文件内容（成功时 cb 给的是路径，不再是全文）。
---@param path string|nil
---@return string|nil
local function readResult(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    os.remove(path)
    return text
end

local function run(ui)
    local result, reason
    local handle = Extract.run(ui, function(path, err) result, reason = path, err end, ignore)
    Stubs.flush()
    return readResult(result), reason, handle
end

local function rollingUi(count, pages)
    local doc = { at = "reading", calls = {}, cost = 0 }
    function doc:getPageCount() return count end
    function doc:getXPointer() return self.at end
    function doc:gotoXPointer(xp) self.at = xp end
    function doc:getPageXPointer(page) return "p" .. page end
    function doc:getTextFromXPointers(pos0, pos1)
        clock = clock + self.cost
        self.calls[#self.calls + 1] = pos0 .. ">" .. pos1
        return pages[tonumber(pos0:sub(2))]
    end
    function doc:gotoPage(page) self.at = "page" .. page end
    function doc:getTextFromPositions(pos0, pos1, no_draw)
        self.calls[#self.calls + 1] = string.format("screen:%d,%d,%d,%d:%s", pos0.x, pos0.y, pos1.x, pos1.y, tostring(no_draw))
        return { text = pages[count] }
    end
    return { document = doc, rolling = {} }
end

local function pagingUi(lines_by_page)
    local doc = {}
    function doc:getPageCount() return #lines_by_page end
    function doc:getPageTextBoxes(page)
        local lines = {}
        for _line_idx, words in ipairs(lines_by_page[page]) do
            local line = {}
            for _word_idx, word in ipairs(words) do line[#line + 1] = { word = word } end
            lines[#lines + 1] = line
        end
        return lines
    end
    return { document = doc, paging = {} }
end

-- 流式：前几页按相邻 xpointer 取，末页按屏幕范围取；相同的边界行只留一份；取完放回阅读位置
do
    local ui = rollingUi(3, { "第一行\n重复行", "重复行\n第二行", "第三行" })
    local text, err = run(ui)
    Assert.is_nil(err)
    Assert.eq(text, "第一行\n重复行\n第二行\n第三行")
    Assert.eq(table.concat(ui.document.calls, ","), "p1>p2,p2>p3,screen:0,0,600,800:true")
    Assert.eq(ui.document.at, "reading")
end

-- 固定版式：按行拼词，相邻两个 ASCII 词之间补空格，中文不加
do
    local text, err = run(pagingUi({
        { { "Hello", "world," }, { "第一", "章" } },
        { { "a", "b" } },
    }))
    Assert.is_nil(err)
    Assert.eq(text, "Hello world,\n第一章\na b")
end

-- 坏页抛错：整次作废，带上原因
do
    local ui = rollingUi(2, { "正文", "结尾" })
    function ui.document:getTextFromXPointers() error("bad page") end
    local text, err = run(ui)
    Assert.is_nil(text)
    Assert.matches(err, "无法提取文字")
    Assert.matches(err, "bad page")
    Assert.eq(ui.document.at, "reading")
end

-- 没有页、只有空白（扫描版 PDF 没有文字层）都算失败
do
    local text, err = run(rollingUi(0, {}))
    Assert.is_nil(text)
    Assert.eq(err, "文档没有可提取的文字")

    text, err = run(pagingUi({ { {} }, { { "", "" } } }))
    Assert.is_nil(text)
    Assert.eq(err, "文档没有可提取的文字")
end

-- 按时长分批，批间 scheduleIn 正延迟（nextTick 链不让出输入）；取消后排队的批不再提取、也不回调
do
    local UIManager = require("ui/uimanager")
    local original_in, original_tick = UIManager.scheduleIn, UIManager.nextTick
    local pending, delays = {}, {}
    UIManager.scheduleIn = function(_self, delay, fn)
        delays[#delays + 1] = delay
        pending[#pending + 1] = fn
    end
    UIManager.nextTick = function() error("extract must not chain nextTick") end
    local function tick() table.remove(pending, 1)() end

    -- 页快：一批取完整本
    local ui = rollingUi(3, { "一", "二", "三" })
    local text, err
    Extract.run(ui, function(path, e) text, err = readResult(path), e end, ignore)
    tick()
    Assert.eq(text, "一\n二\n三")
    Assert.is_nil(err)
    Assert.eq(#pending, 0)

    -- 页慢：一页就用完一批，下一批排队，每批报一次已取页数
    ui = rollingUi(3, { "一", "二", "三" })
    ui.document.cost = 100
    local callbacks = 0
    local reported
    local handle = Extract.run(ui, function() callbacks = callbacks + 1 end,
        function(step, done, total) reported = { step, done, total } end)
    tick()
    Assert.len(ui.document.calls, 1)
    Assert.eq(#pending, 1)
    Assert.eq(table.concat(reported, " "), "正在提取文字 1 3")
    handle.cancel()
    tick()
    Assert.len(ui.document.calls, 1)
    Assert.eq(#pending, 0)
    Assert.eq(callbacks, 0)
    for _idx, delay in ipairs(delays) do Assert.is_true(delay > 0, "延迟必须为正才会轮询输入") end

    -- 中途换了文档：报错收尾，不去碰已关闭文档的阅读位置
    text, err = nil, nil
    ui = rollingUi(3, { "一", "二", "三" })
    ui.document.cost = 100
    local doc = ui.document
    Extract.run(ui, function(t, e) text, err = t, e end, ignore)
    tick()
    ui.document = { file = "other" }
    function doc:gotoXPointer() error("closed document touched") end
    tick()
    Assert.is_nil(text)
    Assert.eq(err, "文档已关闭")
    Assert.eq(#pending, 0)

    UIManager.scheduleIn, UIManager.nextTick = original_in, original_tick
end
