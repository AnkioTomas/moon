--[[--
划词手柄：选区两端的可拖指示器，对齐 Kindle / Android。

不另造选区。手柄只是 selected_text.pos0/pos1/sboxes 的视图；
拖动手柄 = 固定一端，把另一端交给 document:getTextFromPositions。

叠层盖在划词菜单之上：命中手柄就拖，没命中就把事件转给菜单。
菜单锚在选区+手柄的下方或上方，一开始拖就藏菜单，松手再按新手柄位置重开。
已有标注（onShowHighlightMenu 带 index）不出现手柄，仍走原生 Extend。

@module koplugin.book.ui.reader.selection
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local MoonSettings = require("utils.settings")
local Screen = Device.screen

---@class BookReaderSelection
local Selection = {}

--- 缺键或非 false 都算开，旧配置不会被当成关。
---@return boolean
function Selection.enabled()
    return MoonSettings.get("reader").selection_handles_enabled ~= false
end

---@class BookSelectionHandle
---@field x number 圆心
---@field y number 圆心
---@field ax number 描边起点
---@field ay number 描边起点
---@field edge_x number 选区端点（给 getTextFromPositions）
---@field edge_y number 选区端点

---@class BookSelectionAnchors
---@field start BookSelectionHandle
---@field finish BookSelectionHandle

local function metrics()
    return {
        radius = Screen:scaleBySize(7),
        stem = Screen:scaleBySize(10),
        hit = Screen:scaleBySize(22),
        stem_w = math.max(1, Screen:scaleBySize(2)),
        ring = math.max(1, Screen:scaleBySize(2)),
    }
end

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

--- 选区首尾盒转成屏幕坐标。缺盒或变换失败返回 nil。
---@param highlight table
---@return table|nil, table|nil
function Selection.screenBoxes(highlight)
    local selected = highlight and highlight.selected_text
    if not selected then
        return nil
    end
    -- KOReader 的 sboxes 已经是屏幕坐标；只有 pboxes 需要转换。
    local boxes = selected.sboxes
    local page_boxes = false
    if not boxes or #boxes == 0 then
        boxes = selected.pboxes
        page_boxes = true
    end
    if not boxes or #boxes == 0 then
        return nil
    end
    local first, last = boxes[1], boxes[#boxes]
    local ui = highlight.ui
    if page_boxes and ui and ui.paging and ui.view and ui.view.pageToScreenTransform then
        local page = selected.pos0 and selected.pos0.page
        first = ui.view:pageToScreenTransform(page, first)
        last = ui.view:pageToScreenTransform(page, last)
        if not first or not last then
            return nil
        end
    end
    return first, last
end

--- 由屏幕盒算出两端圆心、描边锚点和选区端点。
---@param first table
---@param last table
---@param screen_h number
---@param radius number
---@param stem number
---@return BookSelectionAnchors
function Selection.anchors(first, last, screen_h, radius, stem)
    local function place(edge_x, box)
        local mid_y = box.y + box.h * 0.5
        local bottom = box.y + box.h
        local below_y = bottom + stem + radius
        if below_y + radius <= screen_h then
            return {
                x = edge_x,
                y = below_y,
                ax = edge_x,
                ay = bottom,
                edge_x = edge_x,
                edge_y = mid_y,
            }
        end
        return {
            x = edge_x,
            y = box.y - stem - radius,
            ax = edge_x,
            ay = box.y,
            edge_x = edge_x,
            edge_y = mid_y,
        }
    end
    return {
        start = place(first.x, first),
        finish = place(last.x + last.w, last),
    }
end

--- 选区加手柄占用的竖直区间，菜单必须落在这区间之外。
---@param first table
---@param last table
---@param anchors BookSelectionAnchors
---@param radius number
---@return number, number
function Selection.band(first, last, anchors, radius)
    local text_top = math.min(first.y, last.y)
    local text_bottom = math.max(first.y + first.h, last.y + last.h)
    local handle_top = math.min(anchors.start.y, anchors.finish.y) - radius
    local handle_bottom = math.max(anchors.start.y, anchors.finish.y) + radius
    return math.min(text_top, handle_top), math.max(text_bottom, handle_bottom)
end

--- 菜单锚点：优先手柄下方，放不下再上方。y 是 MovableContainer 的锚点纵坐标。
---@param band_top number
---@param band_bottom number
---@param dialog_h number
---@param screen_h number
---@param padding number
---@return { y: number }, boolean|nil
function Selection.menuAnchor(band_top, band_bottom, dialog_h, screen_h, padding)
    local below = band_bottom + padding
    if below + dialog_h <= screen_h then
        return { y = below }, true
    end
    return { y = band_top - padding }
end

--- 按当前选区/手柄算菜单锚点。算不出则返回 nil，调用方走原生。
---@param highlight table
---@param dialog table|nil
---@return { y: number }|nil, boolean|nil
function Selection.menuAnchorFor(highlight, dialog)
    local first, last = Selection.screenBoxes(highlight)
    if not first or not last then
        return nil
    end
    local size = dialog and dialog.getContentSize and dialog:getContentSize()
    local dialog_h = size and size.h or 0
    if dialog_h <= 0 then
        return nil
    end
    local screen_h = highlight.screen_h or Screen:getHeight()
    local m = metrics()
    local anchors = Selection.anchors(first, last, screen_h, m.radius, m.stem)
    local top, bottom = Selection.band(first, last, anchors, m.radius)
    return Selection.menuAnchor(top, bottom, dialog_h, screen_h, Screen:scaleBySize(2))
end

--- 命中哪个手柄。两端重叠时取更近的。
---@param anchors BookSelectionAnchors|nil
---@param pos { x: number, y: number }|nil
---@param radius number
---@return "start"|"finish"|nil
function Selection.hit(anchors, pos, radius)
    if not anchors or not pos or not radius then
        return nil
    end
    local r2 = radius * radius
    local start_d = dist2(anchors.start.x, anchors.start.y, pos.x, pos.y)
    local finish_d = dist2(anchors.finish.x, anchors.finish.y, pos.x, pos.y)
    local start_hit = start_d <= r2
    local finish_hit = finish_d <= r2
    if start_hit and finish_hit then
        return start_d <= finish_d and "start" or "finish"
    end
    if start_hit then
        return "start"
    end
    if finish_hit then
        return "finish"
    end
    return nil
end

--- 固定一端，把另一端移到 pos。空结果或引擎失败时保持原选区。
---@param highlight table
---@param which "start"|"finish"
---@param pos { x: number, y: number }
---@param fixed { x: number, y: number }
---@return boolean
function Selection.move(highlight, which, pos, fixed)
    local ui = highlight and highlight.ui
    if not ui or not ui.document or not ui.view or not pos or not fixed then
        return false
    end
    -- screenToPageTransform 会写回 page，必须每次新表。
    local finger = ui.view:screenToPageTransform({ x = pos.x, y = pos.y })
    local other = ui.view:screenToPageTransform({ x = fixed.x, y = fixed.y })
    if not finger or not other then
        return false
    end
    local a, b = finger, other
    if which == "finish" then
        a, b = other, finger
    end
    local new = ui.document:getTextFromPositions(a, b)
    if not new or not new.pos0 or not new.text or new.text == "" then
        return false
    end
    highlight.selected_text = new
    highlight.is_word_selection = false
    if ui.paging and highlight.hold_pos and ui.view.highlight then
        ui.view.highlight.temp[highlight.hold_pos.page] = new.sboxes
    end
    return true
end

---@class BookSelectionHandles : InputContainer
local Handles = InputContainer:extend{
    name = "book_selection_handles",
    covers_fullscreen = false,
}

function Handles:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    local rate = Screen.low_pan_rate and 5.0 or 30.0
    local range = function()
        return self.dimen
    end
    self.ges_events = {
        Touch = { GestureRange:new{ ges = "touch", range = range } },
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range, rate = rate } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        Hold = { GestureRange:new{ ges = "hold", range = range } },
        HoldPan = { GestureRange:new{ ges = "hold_pan", range = range, rate = rate } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
    }
    self:layout()
end

function Handles:layout()
    local first, last = Selection.screenBoxes(self.highlight)
    if not first or not last then
        self.anchors = nil
        return
    end
    local m = metrics()
    self.anchors = Selection.anchors(first, last, self.dimen.h, m.radius, m.stem)
    self.hit_radius = m.hit
end

function Handles:which(pos)
    return Selection.hit(self.anchors, pos, self.hit_radius)
end

function Handles:beginDrag(which, pos)
    local other = which == "start" and self.anchors.finish or self.anchors.start
    local handle = self.anchors[which]
    self.dragging = which
    self.fixed = { x = other.edge_x, y = other.edge_y }
    self.grab_dx = handle.edge_x - pos.x
    self.grab_dy = handle.edge_y - pos.y
end

function Handles:drag(pos)
    if not self.dragging or not self.fixed then
        return
    end
    if not self.menu_hidden then
        self.menu_hidden = true
        Selection.hideMenu(self.highlight)
    end
    local moved = Selection.move(self.highlight, self.dragging, {
        x = pos.x + self.grab_dx,
        y = pos.y + self.grab_dy,
    }, self.fixed)
    if not moved then
        return
    end
    self:layout()
    UIManager:setDirty(self.highlight.dialog, "ui")
    UIManager:setDirty(self, "ui")
end

function Handles:endDrag()
    local hidden = self.menu_hidden
    self.dragging = nil
    self.fixed = nil
    self.menu_hidden = nil
    self.grab_dx, self.grab_dy = nil, nil
    self:layout()
    UIManager:setDirty(self, "ui")
    if hidden then
        Selection.showMenu(self.highlight)
    end
end

function Handles:onTouch(_, ges)
    if self.dragging then
        return true
    end
    local which = self:which(ges.pos)
    if not which then
        return false
    end
    self:beginDrag(which, ges.pos)
    return true
end

Handles.onHold = Handles.onTouch

function Handles:onPan(_, ges)
    if not self.dragging then
        return false
    end
    self:drag(ges.pos)
    return true
end

Handles.onHoldPan = Handles.onPan

function Handles:onPanRelease()
    if not self.dragging then
        return false
    end
    self:endDrag()
    return true
end

Handles.onHoldRelease = Handles.onPanRelease

function Handles:onTap(_, ges)
    if self.dragging then
        self:endDrag()
        return true
    end
    return self:which(ges.pos) ~= nil
end

function Handles:onSetDimensions(dimen)
    self.dimen = Geom:new{ x = 0, y = 0, w = dimen.w, h = dimen.h }
    self:layout()
end

function Handles:handleEvent(event)
    if InputContainer.handleEvent(self, event) then
        return true
    end
    local dialog = self.highlight and self.highlight.highlight_dialog
    if dialog then
        return dialog:handleEvent(event)
    end
end

function Handles:onCloseWidget()
    if self._keep then
        return
    end
    local highlight = self.highlight
    if highlight and highlight._book_handles == self then
        highlight._book_handles = nil
    end
end

function Handles:paintTo(bb)
    if not self.anchors then
        return
    end
    local m = metrics()
    local fill = Screen.night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local ring = Screen.night_mode and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local function paint(handle)
        local cx, cy = math.floor(handle.x), math.floor(handle.y)
        local ax, ay = math.floor(handle.ax), math.floor(handle.ay)
        local sw = m.stem_w
        local y0 = math.min(ay, cy)
        local h = math.abs(cy - ay)
        if h > 0 then
            bb:paintRect(math.floor(ax - sw / 2), y0, sw, h, fill)
        end
        if bb.paintCircle then
            bb:paintCircle(cx, cy, m.radius, ring)
            bb:paintCircle(cx, cy, math.max(1, m.radius - m.ring), fill)
        else
            bb:paintRect(cx - m.radius, cy - m.radius, m.radius * 2, m.radius * 2, fill)
        end
    end
    paint(self.anchors.start)
    paint(self.anchors.finish)
end

--- 关掉划词菜单但不清选区。拖动手柄时用。
---@param highlight table|nil
---@return nil
function Selection.hideMenu(highlight)
    local dialog = highlight and highlight.highlight_dialog
    if not dialog then
        return
    end
    dialog.tap_close_callback = nil
    highlight.highlight_dialog = nil
    highlight._book_menu_hidden = true
    UIManager:close(dialog)
end

--- 拖完后按新手柄位置重开菜单。
---@param highlight table|nil
---@return nil
function Selection.showMenu(highlight)
    if not highlight or not highlight.selected_text or not highlight._book_menu_hidden then
        return
    end
    highlight._book_menu_hidden = nil
    if highlight.highlight_dialog or not highlight.onShowHighlightMenu then
        return
    end
    highlight:onShowHighlightMenu(highlight._book_menu_index)
end

--- 菜单重开后叠层会被压到下面，关再开一次抬到栈顶。
---@param highlight table
---@return nil
function Selection.raise(highlight)
    local overlay = highlight._book_handles
    if not overlay then
        return
    end
    overlay._keep = true
    UIManager:close(overlay)
    overlay._keep = false
    UIManager:show(overlay, "ui")
end

--- 划词菜单弹出后挂上手柄。已有标注或非触摸设备不挂。
---@param highlight table|nil
---@param index number|nil
---@return nil
function Selection.attach(highlight, index)
    if not highlight or index or not Device:isTouchDevice() or not Selection.enabled() then
        return
    end
    if not highlight.selected_text or not highlight.highlight_dialog then
        return
    end
    highlight._book_menu_index = index
    if highlight._book_handles then
        highlight._book_handles:layout()
        Selection.raise(highlight)
        return
    end
    local overlay = Handles:new{ highlight = highlight }
    if not overlay.anchors then
        return
    end
    highlight._book_handles = overlay
    UIManager:show(overlay, "ui")
end

--- 关掉手柄叠层。重复调用无副作用。
---@param highlight table|nil
---@return nil
function Selection.detach(highlight)
    local overlay = highlight and highlight._book_handles
    if not overlay then
        return
    end
    highlight._book_handles = nil
    UIManager:close(overlay)
end

local function patchHighlight()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or ReaderHighlight._book_handles_patched then
        return
    end
    ReaderHighlight._book_handles_patched = true

    local orig_show = ReaderHighlight.onShowHighlightMenu
    function ReaderHighlight:onShowHighlightMenu(index)
        local result = orig_show(self, index)
        Selection.attach(self, index)
        return result
    end

    local orig_clear = ReaderHighlight.clear
    function ReaderHighlight:clear(...)
        Selection.detach(self)
        return orig_clear(self, ...)
    end

    local orig_close = ReaderHighlight.onClose
    function ReaderHighlight:onClose(...)
        Selection.detach(self)
        return orig_close(self, ...)
    end
end

--- 安装划词手柄。重复调用无副作用。
---@param _ui table|nil
---@return nil
function Selection.install(_ui)
    patchHighlight()
end

return Selection
