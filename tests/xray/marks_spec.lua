--[[-- xray.marks：只扫描当前可见页并映射到屏幕框。 --]]

local Assert = require("support.assert")
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
            return { page = 0, identity = { source_id = "moon", stable_id = "book", chapter_idx = 0 } }
        end,
    }
end

local Marks = require("xray.marks")

local opened
package.preload["xray.ui"] = function()
    return { showEntity = function(e) opened = e.name end }
end

local entity = { kind = "character", name = "John Doe", aliases = { "John" } }
local list_calls = 0

-- 滚动文档（CreDocument）：下一 tick 只调用视口 findText，不碰全书 findAllText。
package.preload["db.xray"] = function()
    return { list = function() list_calls = list_calls + 1; return { entity } end }
end
package.loaded["db.xray"] = nil
package.loaded["xray.ui"] = nil

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
Marks:rebuild()
Assert.len(Marks._marks, 0, "首帧不能执行文本搜索")
Assert.len(find_calls, 0)
Stubs.flush()
Assert.len(find_calls, 2)
Assert.len(Marks._marks, 2)
Assert.eq(list_calls, 1)
Assert.eq(Marks._marks[1].entity.name, "John Doe")
Assert.eq(Marks._marks[1].box.x, 0)

Marks.invalidate()
Assert.len(Marks._marks, 0)
Assert.eq(Marks._revision, 1)

-- 快速滚动时，旧位置任务必须作废，只扫描最新位置。
Marks:rebuild()
current_pos = 100
Marks:rebuild()
Stubs.flush()
Assert.eq(list_calls, 2, "同一实体 revision 翻页不得重复查库")
Assert.len(find_calls, 4)
Assert.eq(find_calls[3].pos, 100)
Assert.eq(find_calls[4].pos, 100)

-- 分页文档（PDF/DJVU）：koptinterface 只接收 ReaderUI 的实时当前页。
package.loaded["xray.marks"] = nil
Marks = require("xray.marks")
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
package.preload["db.xray"] = function()
    return { list = function() return { { kind = "term", name = "Whitby", aliases = {} } } end }
end
package.loaded["db.xray"] = nil
Marks._render_key = nil
Marks:rebuild()
Assert.len(searched_pages, 0)
Stubs.flush()
Assert.eq(searched_pages[1], 3, "不能使用滞后的 session.page=0")
Assert.len(Marks._marks, 1)
Assert.eq(Marks._marks[1].box.x, 20)
Assert.eq(Marks._marks[1].box.w, 80)

Assert.is_true(Marks:onTap({ pos = { x = 25, y = 12 } }))
Assert.eq(opened, "Whitby")

page = 4
Marks:rebuild()
Stubs.flush()
Assert.eq(searched_pages[2], 4)

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
