--[[-- reader.page_marks：单实例标记层的互斥占位、扣段绘制、点按分发与图层隔离。 --]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function() return { COLOR_DARK_GRAY = 1 } end
package.preload["ui/size"] = function() return { line = { thick = 2 } } end
local reported = {}
package.preload["ui.guard"] = function()
    local broken = {}
    return {
        paint = function(label, fn, ...)
            if broken[label] then return end
            local ok = pcall(fn, ...)
            if not ok then broken[label] = true; reported[#reported + 1] = label end
        end,
        call = function(label, fn, ...)
            local res = { pcall(fn, ...) }
            if res[1] then return unpack(res, 2) end
            reported[#reported + 1] = label
        end,
    }
end

local PageMarks = require("reader.page_marks")

--- 记录每次 paintRect 的横向区间（虚线每段 6px，起点即 x）。
local function newBB()
    local rects = {}
    return { rects = rects, paintRect = function(_bb, x, y, w) rects[#rects + 1] = { x = x, y = y, w = w } end }
end

local function newUi()
    local ui = {
        view = { dimen = { w = 200, h = 200 }, highlight_visible = true, highlight = { visible_boxes = {} } },
        zones = {},
    }
    function ui.view.registerViewModule(_view, name, module) ui.module = { name = name, module = module } end
    function ui.registerTouchZones(_self, list) ui.zones[#ui.zones + 1] = list[1] end
    return ui
end

local function layer(list)
    return { marks = function() return list end }
end

do
    -- 每个 ReaderUI 一个实例：唯一 view module + 唯一点按区，图层按 priority 排序。
    local ui = newUi()
    local inst = PageMarks.add(ui, "reviews", 20, layer({}))
    Assert.eq(PageMarks.add(ui, "xray", 10, layer({})), inst)
    Assert.eq(ui.module.name, "book_page_marks")
    Assert.eq(ui.module.module, inst)
    Assert.len(ui.zones, 1)
    Assert.eq(ui.zones[1].id, "book_page_marks_tap")
    Assert.contains(ui.zones[1].overrides, "tap_forward")
    Assert.eq(inst.layers[1].id, "xray")
    Assert.eq(inst.layers[2].id, "reviews")
end

do
    -- 互斥：自有划线 > X-Ray > 段评，同行已占区间扣掉，只画剩余段；点按只认画出的段。
    local ui = newUi()
    ui.view.highlight.visible_boxes = { { rect = { x = 0, y = 0, w = 20, h = 20 } } }
    local hit = {}
    PageMarks.add(ui, "reviews", 20, layer({ {
        boxes = { { x = 0, y = 0, w = 100, h = 20 }, { x = 0, y = 20, w = 40, h = 20 } },
        tap = function() hit[#hit + 1] = "review" end,
    } }))
    local inst = PageMarks.add(ui, "xray", 10, layer({
        { boxes = { { x = 40, y = 0, w = 20, h = 20 } }, tap = function() hit[#hit + 1] = "xray" end },
        -- 同层后交出的「John」落在「John Doe」里：整段被占，不画。
        { boxes = { { x = 40, y = 0, w = 10, h = 20 } }, tap = function() hit[#hit + 1] = "dup" end },
    }))
    local bb = newBB()
    inst:paintTo(bb)
    Assert.len(inst.painted, 2, "被完全覆盖的标记不画")
    Assert.eq(inst.painted[1].mark.boxes[1].x, 40)
    local pieces = inst.painted[2].pieces
    Assert.len(pieces, 3, "段评首行扣掉划线与实体后剩两段，第二行整段")
    Assert.eq(pieces[1].x, 20); Assert.eq(pieces[1].w, 20)
    Assert.eq(pieces[2].x, 60); Assert.eq(pieces[2].w, 40)
    Assert.eq(pieces[3].y, 20); Assert.eq(pieces[3].w, 40)
    for _idx, rect in ipairs(bb.rects) do
        Assert.is_false(rect.y == 19 and rect.x < 20, "自有划线区内不画下划线")
    end
    Assert.is_true(ui.zones[1].handler({ pos = { x = 45, y = 10 } }))
    Assert.is_true(ui.zones[1].handler({ pos = { x = 70, y = 10 } }))
    Assert.is_false(ui.zones[1].handler({ pos = { x = 10, y = 5 } }), "自有划线处交给原生")
    Assert.is_false(ui.zones[1].handler({ pos = { x = 150, y = 150 } }))
    Assert.eq(table.concat(hit, ","), "xray,review")

    -- 划线隐藏时 visible_boxes 是旧数据，不参与占位。
    ui.view.highlight_visible = false
    inst:paintTo(newBB())
    Assert.eq(inst.painted[2].pieces[1].x, 0)
end

do
    -- 相邻两行只挨着边，不算同行；碎段窄于 4px 不画。
    local ui = newUi()
    ui.view.highlight.visible_boxes = { { rect = { x = 0, y = 0, w = 98, h = 20 } } }
    local inst = PageMarks.add(ui, "reviews", 20, layer({ {
        boxes = { { x = 0, y = 0, w = 100, h = 20 }, { x = 0, y = 20, w = 100, h = 20 } },
        tap = function() end,
    } }))
    inst:paintTo(newBB())
    Assert.len(inst.painted[1].pieces, 1)
    Assert.eq(inst.painted[1].pieces[1].y, 20)
end

do
    -- 一层画坏只停那一层，其它层照画。
    local ui = newUi()
    local inst = PageMarks.add(ui, "xray", 10, { marks = function() error("boom") end })
    PageMarks.add(ui, "reviews", 20, layer({ { boxes = { { x = 0, y = 0, w = 50, h = 20 } }, tap = function() end } }))
    inst:paintTo(newBB())
    Assert.eq(reported[1], "xray.paintTo")
    Assert.len(inst.painted, 1)
end

do
    local box = { x = 10, y = 20, w = 30, h = 20 }
    Assert.is_true(PageMarks.hit({ x = 10, y = 10 }, box), "文字上方留半行容错")
    Assert.is_false(PageMarks.hit({ x = 10, y = 9 }, box))
    Assert.is_false(PageMarks.hit({ x = 41, y = 25 }, box))
    Assert.is_true(PageMarks.intersects({ x = -5, y = 0, w = 10, h = 10 }, 100, 100))
    Assert.is_false(PageMarks.intersects({ x = 0, y = 100, w = 10, h = 10 }, 100, 100))
    Assert.is_false(PageMarks.intersects({ x = 0, y = 0, w = 0, h = 10 }, 100, 100))
    Assert.is_false(PageMarks.intersects(nil, 100, 100))
end

do
    -- 图层可选 paint：画完下划线后自绘，不占位。
    local ui = newUi()
    local painted = 0
    local inst = PageMarks.add(ui, "rare", 30, { marks = function() return {} end, paint = function() painted = painted + 1 end })
    inst:paintTo(newBB())
    Assert.eq(painted, 1)
    Assert.len(inst.painted, 0)
end
