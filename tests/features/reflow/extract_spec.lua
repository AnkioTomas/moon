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
package.preload["json"] = function() return require("support.json_stub") end
-- 假时钟（毫秒）：每页耗时由用例的 doc.cost 决定，分批可预测
local clock = 0
package.preload["utils.perf"] = function() return { now = function() return clock end } end

package.loaded["features.reflow.extract"] = nil
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

-- 流式：有 DOM 接口时整棵倒出，不再逐页；剥标签后按行落盘
do
    local ui = rollingUi(3, { "第一行\n重复行", "重复行\n第二行", "第三行" })
    function ui.document:getHTMLFromXPointer(xp, flags)
        Assert.eq(xp, ".0")
        Assert.eq(flags, 0x0020)
        return "<RootNode><p>第一行</p><p>重复行</p><p>第二行</p><p>第三行</p></RootNode>"
    end
    local text, err = run(ui)
    Assert.is_nil(err)
    Assert.eq(text, "第一行\n重复行\n第二行\n第三行")
    Assert.len(ui.document.calls, 0, "DOM 路径不碰逐页 API")
    Assert.eq(ui.document.at, "reading")
end

-- 流式：没有 DOM 接口（或倒出失败）退回逐页；边界行去重；末页按屏幕取
do
    local ui = rollingUi(3, { "第一行\n重复行", "重复行\n第二行", "第三行" })
    local text, err = run(ui)
    Assert.is_nil(err)
    Assert.eq(text, "第一行\n重复行\n第二行\n第三行")
    Assert.eq(table.concat(ui.document.calls, ","), "p1>p2,p2>p3,screen:0,0,600,800:true")
    Assert.eq(ui.document.at, "reading")
end

-- DOM 倒出失败（空）：退回逐页仍能取到字
do
    local ui = rollingUi(2, { "甲", "乙" })
    function ui.document:getHTMLFromXPointer() return "" end
    local text, err = run(ui)
    Assert.is_nil(err)
    Assert.eq(text, "甲\n乙")
    Assert.is_true(#ui.document.calls > 0, "空 DOM 应退逐页")
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

-- 写盘失败（磁盘满）：整次作废、带原因、临时文件删掉，不交出半本书
do
    local real_open = io.open
    local tmp_path
    io.open = function(path, mode)
        local f = real_open(path, mode)
        if mode == "wb" and f then
            tmp_path = path
            return {
                write = function() return nil, "No space left on device" end,
                close = function() return f:close() end,
            }
        end
        return f
    end
    local ui = rollingUi(2, { "正文", "结尾" })
    local text, err = run(ui)
    io.open = real_open
    Assert.is_nil(text)
    Assert.matches(err, "写入临时文件失败")
    Assert.matches(err, "No space left")
    Assert.is_nil(real_open(tmp_path, "rb"), "临时文件应已删除")
    Assert.eq(ui.document.at, "reading")
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

    -- 页慢：一页就用完一批（cost ≥ BATCH_MS），下一批排队，每批报一次已取页数
    ui = rollingUi(3, { "一", "二", "三" })
    ui.document.cost = 280
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
    ui.document.cost = 280
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

-- 工作目录断点：取消保留，下次同页数接着取；完整成品直接复用
do
    local UIManager = require("ui/uimanager")
    local original_in = UIManager.scheduleIn
    local pending = {}
    UIManager.scheduleIn = function(_self, _delay, fn) pending[#pending + 1] = fn end
    local function tick() table.remove(pending, 1)() end
    local dir = os.tmpname() .. "_reflow"
    require("libs/libkoreader-lfs").mkdir(dir)

    local ui = rollingUi(3, { "一", "二", "三" })
    ui.document.cost = 280
    local first
    local handle = Extract.run(ui, function(path, e) first = { path, e } end, ignore, { dir = dir })
    tick()
    handle.cancel()
    tick()
    Assert.is_nil(first)
    Assert.is_true(Extract.hasCheckpoint(dir), "取消留下断点")

    -- 续跑：从第 2 页接着，不再取第 1 页
    ui = rollingUi(3, { "一", "二", "三" })
    local path, err
    Extract.run(ui, function(p, e) path, err = p, e end, ignore, { dir = dir })
    while #pending > 0 do tick() end
    Assert.is_nil(err)
    local f = assert(io.open(path, "rb"))
    local body = f:read("*a")
    f:close()
    Assert.eq(body, "一\n二\n三")
    Assert.eq(table.concat(ui.document.calls, ","), "p2>p3,screen:0,0,600,800:true", "断点续取跳过已完成页")
    Assert.is_false(Extract.hasCheckpoint(dir))
    Assert.eq(Extract.donePath(dir), path)

    -- 已有成品：立刻交路径，不再碰文档
    ui = rollingUi(3, { "X", "Y", "Z" })
    local reused
    Extract.run(ui, function(p) reused = p end, ignore, { dir = dir })
    Assert.eq(reused, path)
    Assert.len(ui.document.calls, 0)

    Extract.clearCheckpoint(dir)
    Assert.is_nil(Extract.donePath(dir))
    os.remove(dir)
    UIManager.scheduleIn = original_in
end
