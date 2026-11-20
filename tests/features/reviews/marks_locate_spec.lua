--[[-- features.reviews.marks：主线程不读整章，worker 读文件，过期定位不写入。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
require("utils.extension").add("reader.paragraph_lender", { id = "wechat", label = "微信读书" })
Stubs.install()
package.preload["features.reviews.sheet"] = function()
    return { open = function() end }
end
package.preload["l10n"] = function() return { apply = function() end } end

local pending = {}
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            local job = {
                cancelled = false,
                cancel = function(self) self.cancelled = true end,
                run = function(self)
                    if self.cancelled then return end
                    self:finish()
                end,
                -- 模拟取消没拦住的迟到结果，用来核对 generation。
                force = function(self)
                    self:finish()
                end,
                finish = function(self)
                    local ok, result = pcall(worker)
                    if ok then
                        opts.on_done(result)
                    else
                        opts.on_failed(tostring(result))
                    end
                end,
            }
            pending[#pending + 1] = job
            return job
        end,
    }
end

local session
package.preload["reader.session"] = function()
    return { current = function() return session end }
end

local source = { enabled = true, fetches = {}, located = {} }
function source:paragraphReviewsEnabled() return self.enabled end
function source:paragraphHotspotsAsync(identity, cb)
    self.fetches[#self.fetches + 1] = { identity = identity, cb = cb }
    return { cancel = function() self.cancelled = (self.cancelled or 0) + 1 end }
end
function source:locateHotspots(hotspots, html)
    self.located[#self.located + 1] = { html = html, bytes = #html, n = #hotspots }
    return hotspots
end

local chapter_file = os.tmpname()
local html = "<p>本章正文</p>"
local out = assert(io.open(chapter_file, "wb"))
out:write(html)
out:close()

local identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 3, source = source }
session = { identity = identity }

local render_hash, page = 1, 1
local ui = {
    dialog = {},
    view = {
        dimen = { w = 100, h = 100 },
        registerViewModule = function() end,
    },
    document = {
        info = {},
        file = chapter_file,
        getCurrentPos = function() return 0 end,
        getDocumentRenderingHash = function() return render_hash end,
        getPageFromXPointer = function() return 1 end,
        getScreenBoxesFromPositions = function()
            return { { x = 10, y = 10, w = 50, h = 20 } }
        end,
    },
    getCurrentPage = function() return page end,
    registerTouchZones = function() end,
}

local Marks = require("features.reviews.marks")
Marks.install(ui)
local marks = ui._book_reviews_marks

local function deliver(spots)
    source.fetches[#source.fetches].cb(spots)
end

local function spots_for(tag)
    return { { range = tag, text = tag, total = 1, pos0 = "a0", pos1 = "a1" } }
end

-- locateChapter：成功读完整文件；缺文件报错且不调用定位。
do
    local hit
    local src = { locateHotspots = function(_self, hotspots, body)
        hit = { n = #hotspots, bytes = #body, body = body }
        return hotspots
    end }
    local found = Marks.locateChapter(src, chapter_file, { { range = "1" } })
    Assert.eq(hit.bytes, #html)
    Assert.eq(hit.body, html)
    Assert.len(found, 1)
    local ok, err = pcall(Marks.locateChapter, src, chapter_file .. ".missing", { { range = "1" } })
    Assert.is_false(ok)
    Assert.is_true(type(err) == "string" and err ~= "", "缺文件要有错误信息")
end

-- 主线程热点回调不读整章；worker 才读，且不截断。
do
    local opens = {}
    local real_open = io.open
    io.open = function(path, mode)
        if path == chapter_file then
            opens[#opens + 1] = mode or "r"
        end
        return real_open(path, mode)
    end
    pending = {}
    source.located = {}
    marks:updateView()
    Assert.len(source.fetches, 1)
    deliver(spots_for("甲"))
    Assert.len(opens, 0, "主线程不打开章文件")
    Assert.len(source.located, 0, "主线程不定位")
    Assert.len(pending, 1)
    pending[1]:run()
    io.open = real_open
    Assert.len(opens, 1, "worker 读章文件")
    Assert.eq(source.located[1].body or source.located[1].html, html)
    Assert.eq(source.located[1].bytes, #html)
    marks:updateView()
    Assert.len(marks.current, 1)
    Assert.eq(marks.current[1].spot.range, "甲")
end

-- 连续切章：旧定位迟到不得写入；回到同一章时更早的那次也不得覆盖新请求。
pending = {}
source.located = {}
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 4, source = source }
session = { identity = identity }
marks:updateView()
deliver(spots_for("乙"))
Assert.len(pending, 1)
local first = pending[1]
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 5, source = source }
session = { identity = identity }
marks:updateView()
deliver(spots_for("丙"))
Assert.len(pending, 2)
local second = pending[2]
first:force()
marks.render_key = nil
marks:updateView()
Assert.is_true(not marks.data or (marks.current[1] and marks.current[1].spot.range ~= "乙") or #marks.current == 0,
    "旧章定位不得在切章后写入")
-- 明确：若 first 未取消就跑完，generation 应丢掉结果。
if marks.current[1] then
    Assert.is_true(marks.current[1].spot.range ~= "乙")
end
second:run()
marks.render_key = nil
marks:updateView()
Assert.len(marks.current, 1)
Assert.eq(marks.current[1].spot.range, "丙")

pending = {}
source.located = {}
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 6, source = source }
session = { identity = identity }
marks:updateView()
deliver(spots_for("丁"))
local gen1 = pending[#pending]
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 7, source = source }
session = { identity = identity }
marks:updateView()
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 6, source = source }
session = { identity = identity }
marks:updateView()
deliver(spots_for("戊"))
local gen2 = pending[#pending]
gen1:force()
marks.render_key = nil
marks:updateView()
if marks.current[1] then
    Assert.is_true(marks.current[1].spot.range ~= "丁", "回到同章时更早的请求不得覆盖")
end
gen2:run()
marks.render_key = nil
marks:updateView()
Assert.len(marks.current, 1)
Assert.eq(marks.current[1].spot.range, "戊")

-- 取消后的任务再跑不得定位、不得写入。
pending = {}
source.located = {}
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 8, source = source }
session = { identity = identity }
marks:updateView()
deliver(spots_for("己"))
local cancelled = pending[#pending]
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 9, source = source }
session = { identity = identity }
marks:updateView()
local located_before = #source.located
cancelled:run()
Assert.eq(#source.located, located_before, "取消后不再读文件定位")

-- 同一章重复 updateView 不堆积新的热点请求或定位任务。
pending = {}
source.fetches = {}
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 10, source = source }
session = { identity = identity }
marks:updateView()
marks:updateView()
marks:updateView()
Assert.len(source.fetches, 1, "同一章只拉一次热点")
Assert.len(pending, 0, "热点未回时还没有定位任务")
deliver(spots_for("庚"))
Assert.len(pending, 1)
marks:updateView()
Assert.len(source.fetches, 1)
Assert.len(pending, 1, "在飞定位不重复启动")

-- worker 读失败：当错误，不把缺文件当成零条书评。
os.remove(chapter_file)
pending = {}
source.located = {}
identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 11, source = source }
session = { identity = identity }
marks:updateView()
deliver(spots_for("辛"))
pending[#pending]:run()
marks.render_key = nil
marks:updateView()
Assert.len(source.located, 0, "读失败不调用定位")
Assert.len(marks.current, 0)
Assert.not_nil(marks.retry_at, "读失败走重试，而不是写成空结果")

-- 隔离大章：完整交给定位，不截断。测量仅为本机进程，不是真机。
do
    local path = os.tmpname()
    local chunk = "<p>一段用来填充大章的中文句子，保证字节足够长。</p>\n"
    local f = assert(io.open(path, "wb"))
    local target = 3 * 1024 * 1024
    local written = 0
    while written < target do
        f:write(chunk)
        written = written + #chunk
    end
    f:write("<!--END_MARKER-->")
    written = written + #("<!--END_MARKER-->")
    f:close()
    local seen
    local src = { locateHotspots = function(_self, _hotspots, body)
        seen = body
        return {}
    end }
    local started = os.clock()
    Marks.locateChapter(src, path, { { range = "1" } })
    local elapsed = os.clock() - started
    Assert.eq(#seen, written, "大章 HTML 不得截断")
    local marker = "<!--END_MARKER-->"
    Assert.is_true(seen:sub(-#marker) == marker, "大章结尾标记仍在")
    io.stderr:write(string.format(
        "MEASURE marks.locateChapter large chapter bytes=%d elapsed=%.4fs host=local-luajit not-device\n",
        written, elapsed))
    os.remove(path)
end

os.remove(chapter_file)
