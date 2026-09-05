--[[-- xray.marks：页内实体标记（findAllText → 屏幕框）。 --]]

local Assert = require("support.assert")
-- 全书扫描走后台 Job，测试桩把 Job 完成回调排到 nextTick。
local Stubs = require("support.stubs")
Stubs.install()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
local job_runs, job_cancels = 0, 0
local scan_document
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            job_runs = job_runs + 1
            local cancelled = false
            local job = {
                cancel = function()
                    cancelled = true
                    job_cancels = job_cancels + 1
                end,
            }
            require("ui/uimanager"):nextTick(function()
                if cancelled then return end
                local ok, result = pcall(worker, {
                    post = function(message)
                        if not cancelled and opts.on_progress then opts.on_progress(message) end
                    end,
                })
                if cancelled then return end
                if ok then
                    if opts.on_done then opts.on_done(result) end
                elseif opts.on_failed then
                    opts.on_failed(result)
                end
            end)
            return job
        end,
    }
end
package.preload["document/documentregistry"] = function()
    return {
        getProvider = function() return "provider" end,
        openDocument = function() return scan_document end,
    }
end
package.preload["apps/reader/readerui"] = function()
    return { extendProvider = function(_, _, provider) return provider end }
end
package.preload["utils.settings"] = function()
    return { get = function() return {} end }
end
package.preload["ui.reader.session"] = function()
    return {
        current = function()
            return { page = 3, identity = { source_id = "moon", stable_id = "book", chapter_idx = 0 } }
        end,
    }
end

local Marks = require("xray.marks")

local opened
package.preload["xray.ui"] = function()
    return { showEntity = function(e) opened = e.name end }
end

local entity = { kind = "character", name = "John Doe", aliases = { "John" } }

-- 滚动文档（CreDocument）：findAllText 给 xpointer，getScreenBoxesFromPositions 给屏幕框。
package.preload["db.xray"] = function()
    return { list = function() return { entity } end }
end
package.loaded["db.xray"] = nil
package.loaded["xray.ui"] = nil

Marks.ui = {
    getCurrentPage = function() return 1 end,
    dialog = {},
    view = { dimen = { w = 100, h = 50 } },
    document = {
        findAllText = function(document, pattern)
            if pattern == "John Doe" then return { { start = "xp0", ["end"] = "xp1" } } end
            if pattern == "John" then return { { start = "xp2", ["end"] = "xp3" } } end
            return {}
        end,
        getScreenBoxesFromPositions = function(document, start_xp, end_xp)
            if start_xp == "xp0" then return { { x = 0, y = 0, w = 80, h = 20 } } end
            if start_xp == "xp2" then return { { x = 90, y = 0, w = 40, h = 20 } } end
            return {}
        end,
    },
}
Marks.view = Marks.ui.view
Marks.ui.document.file = "book.epub"
Marks.ui.document.close = function() end
scan_document = Marks.ui.document
Marks._matches_key = nil
Marks._render_key = nil
Marks:rebuild()
Assert.len(Marks._marks, 0, "首帧不做全书扫描，标记要等下一 tick")
Assert.eq(job_runs, 1)
Stubs.flush()
Marks:rebuild()
Assert.len(Marks._marks, 2)
Assert.eq(Marks._marks[1].entity.name, "John Doe")
Assert.eq(Marks._marks[1].box.x, 0)

Marks.invalidate()
Assert.len(Marks._matches, 0)
Assert.len(Marks._marks, 0)
Assert.eq(Marks._revision, 1)

-- 实体变化或关书必须取消尚未完成的扫描。
Marks:rebuild()
Assert.eq(job_runs, 2)
Marks.invalidate()
Assert.eq(job_cancels, 1)
Stubs.flush()

-- 分页文档（PDF/DJVU）：findAllText 给页码 + boxes，nativeToPageRectTransform 转页面坐标。
package.loaded["xray.marks"] = nil
Marks = require("xray.marks")
Marks.ui = {
    getCurrentPage = function() return 3 end,
    dialog = {},
    view = {
        dimen = { w = 100, h = 50 },
        pageToScreenTransform = function(view, page, box)
            return { x = box.x * 2, y = box.y * 2, w = box.w * 2, h = box.h * 2 }
        end,
    },
    document = {
        findAllText = function(document, pattern, case_insensitive, context, max_hits)
            return { {
                start = 3,
                boxes = { { x = 10, y = 5, w = 40, h = 20 } },
            } }
        end,
        nativeToPageRectTransform = function(document, page, box)
            return { x = box.x, y = box.y, w = box.w, h = box.h }
        end,
    },
}
Marks.view = Marks.ui.view
Marks.ui.document.file = "book.pdf"
Marks.ui.document.close = function() end
scan_document = Marks.ui.document
package.preload["db.xray"] = function()
    return { list = function() return { { kind = "term", name = "Whitby", aliases = {} } } end }
end
package.loaded["db.xray"] = nil
Marks._matches_key = nil
Marks._render_key = nil
Marks:rebuild()
Stubs.flush()
Marks:rebuild()
Assert.len(Marks._marks, 1)
Assert.eq(Marks._marks[1].box.x, 20)
Assert.eq(Marks._marks[1].box.w, 80)

Assert.is_true(Marks:onTap({ pos = { x = 25, y = 12 } }))
Assert.eq(opened, "Whitby")

-- 开关：setEnabled 持久化并反映到 enabled()。
package.preload["utils.settings"] = function()
    local on = true
    return {
        get = function()
            return { book_xray_show_marks = on }
        end,
        save = function(settings)
            on = settings.book_xray_show_marks ~= false
        end,
    }
end
package.loaded["utils.settings"] = nil
package.loaded["xray.marks"] = nil
Marks = require("xray.marks")
Assert.is_true(Marks.enabled())
Marks.setEnabled(false)
Assert.is_false(Marks.enabled())
Marks.setEnabled(true)
Assert.is_true(Marks.enabled())
