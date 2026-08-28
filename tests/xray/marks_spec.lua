--[[-- xray.marks：页内实体标记（findAllText → 屏幕框）。 --]]

local Assert = require("support.assert")
-- 全书扫描排在 nextTick（同步扫描会卡住绘制），断言前要冲刷
local Stubs = require("support.stubs")
Stubs.install()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["utils.settings"] = function()
    return { get = function() return {} end }
end
package.preload["ui.reader.session"] = function()
    return {
        current = function()
            return { identity = { source_id = "moon", stable_id = "book", chapter_idx = 0 } }
        end,
    }
end

local Marks = require("xray.marks")

local opened
package.preload["xray.ui"] = function()
    return { showEntity = function(e) opened = e.name end }
end

local entity = { kind = "character", name = "John Doe", aliases = { "John" }, payload = {} }

-- 滚动文档（CreDocument）：findAllText 给 xpointer，getScreenBoxesFromPositions 给屏幕框。
package.preload["xray.store"] = function()
    return { loadEntities = function() return { entity } end }
end
package.loaded["xray.store"] = nil
package.loaded["xray.ui"] = nil

Marks.ui = {
    getCurrentPage = function() return 1 end,
    dialog = {},
    view = { dimen = { w = 100, h = 50 } },
    document = {
        findAllText = function(_, pattern)
            if pattern == "John Doe" then return { { start = "xp0", ["end"] = "xp1" } } end
            if pattern == "John" then return { { start = "xp2", ["end"] = "xp3" } } end
            return {}
        end,
        getScreenBoxesFromPositions = function(_, start_xp, end_xp)
            if start_xp == "xp0" then return { { x = 0, y = 0, w = 80, h = 20 } } end
            if start_xp == "xp2" then return { { x = 90, y = 0, w = 40, h = 20 } } end
            return {}
        end,
    },
}
Marks.view = Marks.ui.view
Marks._matches_key = nil
Marks._render_key = nil
Marks:rebuild()
Assert.len(Marks._marks, 0, "首帧不做全书扫描，标记要等下一 tick")
Stubs.flush()
Marks:rebuild()
Assert.len(Marks._marks, 2)
Assert.eq(Marks._marks[1].entity.name, "John Doe")
Assert.eq(Marks._marks[1].box.x, 0)

Marks.invalidate()
Assert.len(Marks._matches, 0)
Assert.len(Marks._marks, 0)

-- 分页文档（PDF/DJVU）：findAllText 给页码 + boxes，nativeToPageRectTransform 转页面坐标。
package.loaded["xray.marks"] = nil
Marks = require("xray.marks")
Marks.ui = {
    getCurrentPage = function() return 3 end,
    dialog = {},
    view = {
        dimen = { w = 100, h = 50 },
        pageToScreenTransform = function(_, page, box)
            return { x = box.x * 2, y = box.y * 2, w = box.w * 2, h = box.h * 2 }
        end,
    },
    document = {
        findAllText = function(_, pattern, ci, ctx, max)
            return { {
                start = 3,
                boxes = { { x = 10, y = 5, w = 40, h = 20 } },
            } }
        end,
        nativeToPageRectTransform = function(_, page, box)
            return { x = box.x, y = box.y, w = box.w, h = box.h }
        end,
    },
}
Marks.view = Marks.ui.view
package.preload["xray.store"] = function()
    return { loadEntities = function() return { { kind = "term", name = "Whitby", aliases = {}, payload = {} } } end }
end
package.loaded["xray.store"] = nil
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
