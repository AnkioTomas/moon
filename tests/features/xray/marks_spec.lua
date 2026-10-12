--[[-- features.xray.marks：只扫描当前可见页并映射到屏幕框。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["utils.settings"] = function()
    local xray = { book_xray_enabled = true, book_xray_show_marks = true }
    return { get = function(name) assert(name == "features.xray"); return xray end }
end
local job_runs, job_cancels = 0, 0
local hold_jobs = false
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            job_runs = job_runs + 1
            local job = { settled = false }
            function job:cancel()
                if self.settled then return end
                self.settled = true
                job_cancels = job_cancels + 1
            end
            if not hold_jobs then
                require("ui/uimanager"):nextTick(function()
                    if job.settled then return end
                    local ok, result = pcall(worker)
                    job.settled = true
                    if ok then
                        if opts.on_done then opts.on_done(result) end
                    elseif opts.on_failed then
                        opts.on_failed(result)
                    end
                end)
            end
            return job
        end,
    }
end
package.preload["reader.session"] = function()
    return {
        current = function()
            return { page = 0, identity = { source_id = "moon", stable_id = "book", chapter_idx = 0 } }
        end,
    }
end

local Marks = require("features.xray.marks")

local opened
package.preload["features.xray.ui"] = function()
    return { showEntity = function(entity) opened = entity.name end }
end

local entity = { kind = "character", name = "John Doe", aliases = { "John" } }
local list_calls = 0

-- 滚动文档（CreDocument）：下一 tick 只调用视口 findText，不碰全书 findAllText。
package.preload["features.xray.db"] = function()
    return { list = function() list_calls = list_calls + 1; return { entity } end }
end
package.loaded["features.xray.db"] = nil

local current_pos = 0
local find_calls = {}
Marks.ui = {
    getCurrentPage = function() return 1 end,
    dialog = {},
    view = { dimen = { w = 100, h = 50 } },
    document = {
        getCurrentPos = function() return current_pos end,
        findAllText = function()
            error("X-Ray must not scan the whole document")
        end,
        findText = function(document, pattern)
            find_calls[#find_calls + 1] = { pattern = pattern, pos = current_pos }
            if pattern == "John Doe" then return { { start = "xp0", ["end"] = "xp1" } } end
            if pattern == "John" then return { { start = "xp2", ["end"] = "xp3" } } end
            return {}
        end,
        getScreenBoxesFromPositions = function(document, start_xp, end_xp)
            if start_xp == "xp0" then return { { x = 0, y = 0, w = 80, h = 20 } } end
            -- 左上角出屏但矩形仍与屏幕相交，也必须保留。
            if start_xp == "xp2" then return { { x = 90, y = 0, w = 40, h = 20 } } end
            return {}
        end,
    },
}
Marks.view = Marks.ui.view
Marks._render_key = nil
Marks:updateView()
Assert.len(Marks._marks, 0, "首帧不能执行文本搜索")
Assert.len(find_calls, 0)
Stubs.flush()
Assert.eq(job_runs, 1)
Assert.len(find_calls, 2)
Assert.len(Marks._marks, 2)
Assert.eq(list_calls, 1)
Assert.eq(Marks._marks[1].entity.name, "John Doe")
Assert.eq(Marks._marks[1].box.x, 0)

Marks.invalidate()
Assert.len(Marks._marks, 0)
Assert.eq(Marks._revision, 1)

-- 快速滚动时，旧位置任务必须作废，只扫描最新位置。
Marks:updateView()
current_pos = 100
Marks:updateView()
Stubs.flush()
Assert.eq(job_runs, 2, "防抖后只能为最新位置启动一个任务")
Assert.eq(job_cancels, 0, "尚未启动的防抖任务不需要取消")
Assert.eq(list_calls, 2, "同一实体 revision 翻页不得重复查库")
Assert.len(find_calls, 4)
Assert.eq(find_calls[3].pos, 100)
Assert.eq(find_calls[4].pos, 100)

-- 防抖结束后已排队的旧页任务，也必须在下一次翻页时取消。
hold_jobs = true
current_pos = 200
Marks:updateView()
Stubs.flush()
Assert.eq(job_runs, 3)
current_pos = 300
Marks:updateView()
Assert.eq(job_cancels, 1)
hold_jobs = false
Stubs.flush()
Assert.eq(job_runs, 4)
Assert.eq(find_calls[5].pos, 300)
Assert.eq(find_calls[6].pos, 300)

-- 能取到屏幕文字时先本地粗筛：只对屏上出现的名字调用 findText。
Marks.ui.rolling = {}
Marks.ui.document.getTextFromPositions = function()
    return { text = "John walked in." }
end
find_calls = {}
current_pos = 400
Marks:updateView()
Stubs.flush()
Assert.len(find_calls, 1)
Assert.eq(find_calls[1].pattern, "John")
Assert.len(Marks._marks, 1)
Marks.ui.rolling = nil
Marks.ui.document.getTextFromPositions = nil

-- 分页文档（PDF/DJVU）：koptinterface 只接收 ReaderUI 的实时当前页。
package.loaded["features.xray.marks"] = nil
Marks = require("features.xray.marks")
local page = 3
local searched_pages = {}
Marks.ui = {
    getCurrentPage = function() return page end,
    dialog = {},
    view = {
        dimen = { w = 100, h = 50 },
        pageToScreenTransform = function(view, page, box)
            return { x = box.x * 2, y = box.y * 2, w = box.w * 2, h = box.h * 2 }
        end,
    },
    document = {
        findAllText = function()
            error("X-Ray must not scan the whole document")
        end,
        koptinterface = {
            findAllMatches = function(interface, document, pattern, case_insensitive, current_page)
                searched_pages[#searched_pages + 1] = current_page
                return { { x = 10, y = 5, w = 40, h = 20 } }
            end,
        },
    },
}
Marks.view = Marks.ui.view
package.preload["features.xray.db"] = function()
    return { list = function() return { { kind = "term", name = "Whitby", aliases = {} } } end }
end
package.loaded["features.xray.db"] = nil
Marks._render_key = nil
Marks:updateView()
Assert.len(searched_pages, 0)
Stubs.flush()
Assert.eq(job_runs, 6)
Assert.eq(searched_pages[1], 3, "不能使用滞后的 session.page=0")
Assert.len(Marks._marks, 1)
Assert.eq(Marks._marks[1].box.x, 20)
Assert.eq(Marks._marks[1].box.w, 80)

-- 交给标记层的图层数据：一个实体一条，点按弹详情。
local layer_marks = Marks:marks()
Assert.len(layer_marks, 1)
Assert.eq(layer_marks[1].boxes[1].x, 20)
Assert.is_false(layer_marks[1].solid)
Assert.is_nil(opened)
layer_marks[1].tap()
Assert.eq(opened, "Whitby")

page = 4
Marks:updateView()
Stubs.flush()
Assert.eq(searched_pages[2], 4)

-- 开关：setEnabled 持久化并反映到 enabled()。
package.preload["utils.settings"] = function()
    local xray = { book_xray_enabled = true, book_xray_show_marks = true }
    return {
        get = function(name) assert(name == "features.xray"); return xray end,
        save = function(name) assert(name == "features.xray") end,
    }
end
package.loaded["utils.settings"] = nil
package.loaded["features.xray.marks"] = nil
Marks = require("features.xray.marks")
Assert.is_true(Marks.enabled())
Marks.setEnabled(false)
Assert.is_false(Marks.enabled())
Assert.len(Marks:marks(), 0, "关掉后不交标记")
Marks.setEnabled(true)
Assert.is_true(Marks.enabled())

-- 挂到阅读页公共标记层：唯一 view module + 全屏点按区，未命中透传。
local registered_module
local registered_touch_zones
local ui = {
    view = {
        dimen = { w = 100, h = 50 },
        registerViewModule = function(_, name, module)
            registered_module = { name = name, module = module }
        end,
    },
    registerTouchZones = function(_, zones)
        registered_touch_zones = zones
    end,
}
Marks.install(ui)
Assert.eq(registered_module.name, "book_page_marks")
Assert.eq(registered_module.module, ui._book_page_marks)
Assert.eq(ui._book_page_marks.layers[1].layer, Marks)
Assert.eq(registered_touch_zones[1].id, "book_page_marks_tap")
Assert.is_false(registered_touch_zones[1].handler({ pos = { x = 9999, y = 9999 } }))
