--[[-- ui.reader.selection：划词手柄几何、拖拽与生命周期。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end

local shown, closed, dirty = {}, {}, {}
local shown_region, closed_mode, dirty_mode, dirty_region
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget, _, region)
            shown[#shown + 1] = widget
            shown_region = region
        end,
        close = function(_, widget, mode)
            closed[#closed + 1] = widget
            closed_mode = mode
        end,
        setDirty = function(_, widget, mode, region)
            dirty[#dirty + 1] = widget
            dirty_mode, dirty_region = mode, region
        end,
    }
end

local touch = true
package.preload["device"] = function()
    return {
        isTouchDevice = function() return touch end,
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, n) return n end,
            low_pan_rate = false,
            night_mode = false,
        },
    }
end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end

package.preload["ui/geometry"] = function()
    local Geom = { x = 0, y = 0, w = 0, h = 0 }
    function Geom:new(o)
        o = o or {}
        o.x, o.y = o.x or 0, o.y or 0
        o.w, o.h = o.w or 0, o.h or 0
        return setmetatable(o, { __index = self })
    end
    function Geom:combine(o)
        local x, y = math.min(self.x, o.x), math.min(self.y, o.y)
        return Geom:new{
            x = x, y = y,
            w = math.max(self.x + self.w, o.x + o.w) - x,
            h = math.max(self.y + self.h, o.y + o.h) - y,
        }
    end
    return Geom
end

package.preload["ui/gesturerange"] = function()
    local GestureRange = {}
    function GestureRange:new(o)
        return o
    end
    return GestureRange
end

local handles_on = true
package.preload["utils.settings"] = function()
    return {
        get = function()
            return { selection_handles_enabled = handles_on }
        end,
    }
end

local InputContainer = {}
function InputContainer:extend(def)
    setmetatable(def, { __index = self })
    def.__index = def
    return def
end
function InputContainer:new(o)
    o = o or {}
    setmetatable(o, self)
    if o.init then o:init() end
    return o
end
function InputContainer:handleEvent()
    return false
end
package.preload["ui/widget/container/inputcontainer"] = function()
    return InputContainer
end

local ReaderHighlight = {
    onShowHighlightMenu = function(self, index)
        self.shown_index = index
        self.highlight_dialog = { id = "menu" }
    end,
    clear = function(self)
        self.cleared = true
    end,
    onClose = function(self)
        self.closed = true
    end,
}
package.preload["apps/reader/modules/readerhighlight"] = function()
    return ReaderHighlight
end

local Selection = require("ui.reader.selection")

-- 几何：首尾盒、贴底 / 翻到上方、命中与落空
local first = { x = 40, y = 100, w = 80, h = 20 }
local last = { x = 200, y = 100, w = 60, h = 20 }
local anchors = Selection.anchors(first, last, 800, 7, 10)
Assert.eq(anchors.start.edge_x, 40)
Assert.eq(anchors.finish.edge_x, 260)
Assert.eq(anchors.start.ay, 120)
Assert.eq(anchors.start.y, 137)
Assert.eq(anchors.start.edge_y, 110)
Assert.eq(anchors.finish.y, 137)

local flipped = Selection.anchors(
    { x = 10, y = 770, w = 40, h = 20 },
    { x = 80, y = 770, w = 40, h = 20 },
    800, 7, 10
)
Assert.is_true(flipped.start.y < 770)
Assert.eq(flipped.start.ay, 770)
Assert.eq(flipped.start.edge_y, 780)

Assert.eq(Selection.hit(anchors, { x = 40, y = 137 }, 22), "start")
Assert.eq(Selection.hit(anchors, { x = 260, y = 137 }, 22), "finish")
Assert.is_nil(Selection.hit(anchors, { x = 150, y = 400 }, 22))
Assert.is_nil(Selection.hit(nil, { x = 40, y = 137 }, 22))
Assert.eq(Selection.hit({
    start = { x = 10, y = 10 },
    finish = { x = 12, y = 10 },
}, { x = 11, y = 10 }, 8), "start")
Assert.eq(Selection.hit({
    start = { x = 10, y = 10 },
    finish = { x = 12, y = 10 },
}, { x = 12, y = 10 }, 8), "finish")

-- 菜单锚点：手柄下方优先，贴底时翻到上方
local band_top, band_bottom = Selection.band(first, last, anchors, 7)
Assert.eq(band_top, 100)
Assert.eq(band_bottom, 144)
local below, pop_down = Selection.menuAnchor(band_top, band_bottom, 80, 800, 2)
Assert.eq(below.y, 146)
Assert.is_true(pop_down)
local above, above_down = Selection.menuAnchor(band_top, band_bottom, 80, 200, 2)
Assert.eq(above.y, 98)
Assert.is_nil(above_down)
local placed = Selection.menuAnchorFor({
    selected_text = { sboxes = { first, last } },
    screen_h = 800,
    ui = {},
}, { getContentSize = function() return { h = 80 } end })
Assert.eq(placed.y, 146)
Assert.is_nil(Selection.menuAnchorFor({ selected_text = { sboxes = {} } }, { getContentSize = function() return { h = 80 } end }))
Assert.is_nil(Selection.menuAnchorFor({
    selected_text = { sboxes = { first, last } },
    ui = {},
}, { getContentSize = function() return { h = 0 } end }))

local rolling = {
    selected_text = { sboxes = { first, last } },
    ui = {},
}
local box0, box1 = Selection.screenBoxes(rolling)
Assert.eq(box0.x, 40)
Assert.eq(box1.x, 200)
Assert.is_nil(Selection.screenBoxes({}))
Assert.is_nil(Selection.screenBoxes({ selected_text = { sboxes = {} } }))

local transformed = {}
local paging = {
    selected_text = {
        pos0 = { page = 3 },
        sboxes = { first, last },
    },
    ui = {
        paging = true,
        view = {
            pageToScreenTransform = function(_, page, box)
                transformed[#transformed + 1] = page
                return { x = box.x + 5, y = box.y, w = box.w, h = box.h }
            end,
        },
    },
}
local p0, p1 = Selection.screenBoxes(paging)
Assert.eq(p0.x, 40)
Assert.eq(p1.x, 200)
Assert.eq(#transformed, 0)

local paging_page_boxes = {
    selected_text = {
        pos0 = { page = 3 },
        pboxes = { first, last },
    },
    ui = paging.ui,
}
local pp0, pp1 = Selection.screenBoxes(paging_page_boxes)
Assert.eq(pp0.x, 45)
Assert.eq(pp1.x, 205)
Assert.eq(transformed[1], 3)
Assert.eq(transformed[2], 3)

-- 拖拽：固定一端，拒绝空结果，交叉时仍用按下时的固定点
local calls = {}
local highlight = {
    hold_pos = { page = 1 },
    selected_text = { text = "原", pos0 = "a", pos1 = "b" },
    ui = {
        paging = true,
        view = {
            screenToPageTransform = function(_, pos)
                return { x = pos.x, y = pos.y, page = 1 }
            end,
            highlight = { temp = {} },
        },
        document = {
            getTextFromPositions = function(_, a, b)
                calls[#calls + 1] = { a = a, b = b }
                if a.x == b.x then
                    return { text = "", pos0 = "z" }
                end
                return {
                    text = "新",
                    pos0 = a,
                    pos1 = b,
                    sboxes = { { x = a.x, y = 100, w = 20, h = 20 } },
                }
            end,
        },
    },
}
Assert.is_true(Selection.move(highlight, "finish", { x = 300, y = 110 }, { x = 40, y = 110 }))
Assert.eq(highlight.selected_text.text, "新")
Assert.eq(highlight.is_word_selection, false)
Assert.eq(calls[1].a.x, 40)
Assert.eq(calls[1].b.x, 300)
Assert.eq(highlight.ui.view.highlight.temp[1][1].x, 40)

Assert.is_false(Selection.move(highlight, "start", { x = 40, y = 110 }, { x = 40, y = 110 }))
Assert.eq(highlight.selected_text.text, "新")
Assert.is_false(Selection.move(highlight, "finish", { x = 1, y = 1 }, nil))

-- 生命周期：新划词才挂，已有标注 / 非触摸不挂；detach 可重复
Selection.install()
Assert.is_true(ReaderHighlight._book_handles_patched)

local fresh = {
    selected_text = { sboxes = { first, last }, text = "词" },
    highlight_dialog = { id = "menu", movable = { dimen = { x = 0, y = 146, w = 600, h = 80 } } },
    ui = {},
    dialog = { id = "reader" },
}
Assert.is_true(Selection.attach(fresh))
Assert.not_nil(fresh._book_handles)
Assert.eq(#shown, 1)
Assert.eq(shown[1], fresh._book_handles)
Assert.eq(fresh._book_handles.anchors.start.edge_x, 40)
Assert.eq(shown_region.y, 100, "叠层只刷选区横带，不刷整屏")
Assert.eq(shown_region.h, 44)
Assert.eq(shown_region.w, 600)

-- 按下末端手柄：固定点是起始端，手指偏移要扣掉
local drag_calls = {}
fresh.hold_pos = { page = 1 }
fresh.ui = {
    view = {
        screenToPageTransform = function(_, pos)
            return { x = pos.x, y = pos.y }
        end,
        highlight = { temp = {} },
    },
    document = {
        getTextFromPositions = function(_, a, b)
            drag_calls[#drag_calls + 1] = { a = a, b = b }
            return {
                text = "拖",
                pos0 = a,
                pos1 = b,
                sboxes = { first, { x = b.x - 20, y = 100, w = 20, h = 20 } },
            }
        end,
    },
}
local overlay = fresh._book_handles
overlay:layout()
local menu_before = fresh.highlight_dialog
fresh.onShowHighlightMenu = function(self)
    self.highlight_dialog = { id = "menu2" }
    self.reshown = true
end
Assert.is_true(overlay:onTouch(nil, { pos = { x = 260, y = 137 } }))
Assert.eq(overlay.dragging, "finish")
Assert.eq(overlay.fixed.x, 40)
Assert.eq(fresh.highlight_dialog, menu_before, "按下还没拖，菜单还在")
Assert.is_true(overlay:onPan(nil, { pos = { x = 300, y = 137 } }))
Assert.eq(drag_calls[1].a.x, 40)
Assert.eq(drag_calls[1].b.x, 300)
Assert.is_nil(fresh.highlight_dialog, "一开始拖就藏菜单")
Assert.eq(closed[1], menu_before)
Assert.eq(closed_mode, "ui", "藏菜单不闪")
Assert.eq(dirty[#dirty], fresh.dialog)
Assert.eq(dirty_mode, "ui")
Assert.eq(dirty_region.y, 100, "拖动只刷选区横带")
Assert.eq(dirty_region.h, 44)
Assert.is_true(overlay:onPanRelease())
Assert.is_nil(overlay.dragging)
Assert.is_true(fresh.reshown)
Assert.eq(fresh.highlight_dialog.id, "menu2")
Assert.is_false(overlay:onTap(nil, { pos = { x = 150, y = 400 } }))
Assert.is_true(overlay:onTap(nil, { pos = { x = overlay.anchors.start.x, y = overlay.anchors.start.y } }))

local forwarded
fresh.highlight_dialog.handleEvent = function(_, event)
    forwarded = event.handler
    return true
end
Assert.is_true(overlay:handleEvent({ handler = "onGesture", args = { n = 0 } }))
Assert.eq(forwarded, "onGesture")

local shown_before_raise = #shown
Assert.is_true(Selection.attach(fresh))
Assert.eq(#shown, shown_before_raise + 1, "菜单重开后叠层抬到栈顶")
Assert.eq(fresh._book_handles, overlay)
Assert.not_nil(shown_region, "抬栈也只刷选区横带")

local existing = {
    selected_text = { sboxes = { first, last } },
    highlight_dialog = { id = "menu" },
}
Assert.is_false(Selection.attach(existing, 2))
Assert.is_nil(existing._book_handles)

touch = false
local keyboard = {
    selected_text = { sboxes = { first, last } },
    highlight_dialog = { id = "menu" },
}
Selection.attach(keyboard)
Assert.is_nil(keyboard._book_handles)
touch = true

handles_on = false
Assert.is_false(Selection.enabled())
local disabled = {
    selected_text = { sboxes = { first, last } },
    highlight_dialog = { id = "menu" },
}
Selection.attach(disabled)
Assert.is_nil(disabled._book_handles, "设置关掉就不挂手柄")
handles_on = true
Assert.is_true(Selection.enabled())

local overlay_ref = fresh._book_handles
Selection.detach(fresh)
Assert.is_nil(fresh._book_handles)
Assert.eq(closed[#closed], overlay_ref)
local closed_n = #closed
Selection.detach(fresh)
Assert.eq(#closed, closed_n)

-- 补丁：弹菜单挂手柄由 highlight_menu 负责，这里不再包一层；clear / onClose 拆掉
local instance = {
    selected_text = { sboxes = { first, last }, text = "词" },
    highlight_dialog = { id = "menu" },
    ui = {},
    dialog = { id = "reader" },
}
ReaderHighlight.onShowHighlightMenu(instance)
Assert.is_nil(instance._book_handles, "onShowHighlightMenu 不重复 attach")
Selection.attach(instance)
Assert.not_nil(instance._book_handles)

ReaderHighlight.clear(instance)
Assert.is_true(instance.cleared)
Assert.is_nil(instance._book_handles)

instance.selected_text = { sboxes = { first, last }, text = "词" }
instance.highlight_dialog = { id = "menu" }
Selection.attach(instance)
ReaderHighlight.onClose(instance)
Assert.is_true(instance.closed)
Assert.is_nil(instance._book_handles)

