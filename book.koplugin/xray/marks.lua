--[[--
页内 X-Ray 实体标记：已入库人物 / 地点 / 专有名词虚线下划线，点击弹出详情。

@module koplugin.book.xray.marks
--]]

require("l10n").apply()

local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Marks = {
    view = nil,
    ui = nil,
    _marks = {},
    _render_key = nil,
    _revision = 0,
    _scan_pending = nil,
    _entity_cache_key = nil,
    _entity_cache = nil,
}

--- 页内实体标记是否开启。
---@return boolean
function Marks.enabled()
    local settings = require("utils.settings").get()
    return settings.book_xray_enabled ~= false
        and settings.book_xray_show_marks ~= false
end

--- 开关页内实体标记并刷新当前阅读视图。
---@param on boolean|nil
---@param ui table|nil
function Marks.setEnabled(on, ui)
    local MoonSettings = require("utils.settings")
    local settings = MoonSettings.get()
    settings.book_xray_show_marks = on ~= false
    MoonSettings.save(settings)
    Marks.invalidate()
    ui = ui or Marks.ui
    if ui and ui.dialog then
        UIManager:setDirty(ui.dialog, "ui")
    end
end

---@return table[]
local function loadEntities()
    local cur = require("ui.reader.session").current()
    local identity = cur and cur.identity
    if not identity then
        return {}
    end
    local key = identity.source_id .. "\0" .. identity.stable_id
        .. "\0" .. tostring(Marks._revision)
    if Marks._entity_cache_key ~= key then
        Marks._entity_cache_key = key
        Marks._entity_cache = require("db.xray").list(identity.source_id, identity.stable_id)
    end
    return Marks._entity_cache
end

---@param ui table
---@return number|nil, number|nil
local function screenSize(ui)
    local view = ui and ui.view
    if view and view.dimen and view.dimen.w and view.dimen.h then
        return view.dimen.w, view.dimen.h
    end
    local ok, Device = pcall(require, "device")
    local screen = ok and Device and Device.screen
    if screen then
        return screen:getWidth(), screen:getHeight()
    end
    return nil, nil
end

--- 读取阅读器实时页码；session.page 可能晚于当前绘制帧。
---@param ui table|nil
---@return integer
local function currentPage(ui)
    if ui and ui.getCurrentPage then
        local ok, page = pcall(ui.getCurrentPage, ui)
        if ok and tonumber(page) then return tonumber(page) end
    end
    local paging = ui and ui.paging
    if paging and tonumber(paging.current_page) then
        return tonumber(paging.current_page)
    end
    local rolling = ui and ui.rolling
    if rolling and tonumber(rolling.current_page) then
        return tonumber(rolling.current_page)
    end
    local document = ui and ui.document
    if document and document.getCurrentPage then
        local ok, page = pcall(document.getCurrentPage, document)
        if ok and tonumber(page) then return tonumber(page) end
    end
    return 0
end

--- 展平实体名与别名，并去重。
---@param entities table[]
---@return table[]
local function collectNames(entities)
    local names = {}
    local seen = {}
    for index, entity in ipairs(entities) do
        local candidates = { entity.name }
        for index, alias in ipairs(entity.aliases) do
            candidates[#candidates + 1] = alias
        end
        for index, name in ipairs(candidates) do
            name = Text.trim(name)
            local normalized = name:lower()
            if name ~= "" and not seen[normalized] then
                seen[normalized] = true
                names[#names + 1] = { name = name, entity = entity }
            end
        end
    end
    return names
end

---@param box table|nil
---@param width number|nil
---@param height number|nil
---@return boolean
local function intersectsScreen(box, width, height)
    return box ~= nil and box.x ~= nil and box.y ~= nil and box.w ~= nil and box.h ~= nil
        and box.w > 0 and box.h > 0
        and (not width or (box.x < width and box.x + box.w > 0))
        and (not height or (box.y < height and box.y + box.h > 0))
end

--- 仅查当前可见页，并直接解析成屏幕框。
---@param ui table
---@param entities table[]
---@return table[]
local function scanVisibleMarks(ui, entities)
    local document = ui and ui.document
    if not document then
        return {}
    end
    local width, height = screenSize(ui)
    local out = {}

    local function addMark(entity, box)
        out[#out + 1] = {
            entity = entity,
            box = { x = box.x, y = box.y, w = box.w, h = box.h },
        }
    end

    local names = collectNames(entities)
    if document.getScreenBoxesFromPositions and document.findText then
        for _, item in ipairs(names) do
            -- CRE 的 findText 只搜索当前视口附近有限高度；结果仍按屏幕相交严格裁剪。
            local ok, matches = pcall(document.findText, document,
                item.name, 0, 0, true, nil, false, 5000, 0)
            if ok and matches then
                for _, match in ipairs(matches) do
                    local start_xp = match and match.start
                    local end_xp = match and match["end"]
                    if start_xp and end_xp then
                        local boxes_ok, boxes = pcall(document.getScreenBoxesFromPositions,
                            document, start_xp, end_xp, true)
                        if boxes_ok and boxes then
                            for _, box in ipairs(boxes) do
                                if intersectsScreen(box, width, height) then
                                    addMark(item.entity, box)
                                end
                            end
                        end
                    end
                end
            end
        end
        -- findText 会把最后一次命中写进 CRE 原生 selection；X-Ray 只需要坐标。
        if document.clearSelection then
            pcall(document.clearSelection, document)
        end
        return out
    end

    local page = currentPage(ui)
    local kopt = document.koptinterface
    if page < 1 or not kopt or not kopt.findAllMatches then
        return out
    end
    for _, item in ipairs(names) do
        local ok, boxes = pcall(kopt.findAllMatches, kopt, document, item.name, true, page)
        if ok and boxes then
            for _, page_box in ipairs(boxes) do
                local screen_box = page_box
                local view = ui.view
                if view and view.pageToScreenTransform then
                    local transformed_ok, transformed = pcall(
                        view.pageToScreenTransform, view, page, page_box)
                    if transformed_ok and transformed then
                        screen_box = transformed
                    else
                        screen_box = nil
                    end
                end
                if screen_box and intersectsScreen(screen_box, width, height) then
                    addMark(item.entity, screen_box)
                end
            end
        end
    end
    return out
end

--- 清空当前屏幕标记；已排队任务会按缓存键自行作废。
---@param self table
local function resetMarks(self)
    self._marks = {}
    self._render_key = nil
    self._scan_pending = nil
end

--- 当前视口缓存键：身份 + 实体修订号 + 屏幕尺寸 + 实时页码/滚动位置。
---@param ui table
---@return string|nil 无阅读会话时 nil
local function renderKey(ui)
    local cur = require("ui.reader.session").current()
    if not cur or not cur.identity then
        return nil
    end
    local w, h = screenSize(ui)
    local doc = ui and ui.document
    local pos = ""
    if doc and doc.getCurrentPos then
        local ok, p = pcall(doc.getCurrentPos, doc)
        if ok then pos = tostring(p or "") end
    end
    return table.concat({
        cur.identity.source_id, cur.identity.stable_id,
        tostring(cur.identity.chapter_idx or 0), tostring(Marks._revision),
        tostring(w or 0), tostring(h or 0), tostring(currentPage(ui)), pos,
    }, "\0")
end

--- 把当前页扫描排到首帧之后；快速翻页时旧键任务直接作废。
---@param self table
---@param key string
---@param entities table[]
local function scheduleScan(self, key, entities)
    if self._scan_pending == key then
        return
    end
    self._scan_pending = key
    local ui = self.ui
    UIManager:nextTick(function()
        if self._scan_pending ~= key or self.ui ~= ui then
            return
        end
        if not Marks.enabled() or renderKey(ui) ~= key then
            if self._scan_pending == key then self._scan_pending = nil end
            return
        end
        local marks = scanVisibleMarks(ui, entities)
        if self._scan_pending ~= key or self.ui ~= ui
            or not Marks.enabled() or renderKey(ui) ~= key then
            return
        end
        self._scan_pending = nil
        self._marks = marks
        self._render_key = key
        if ui.dialog then
            UIManager:setDirty(ui.dialog, "ui")
        end
    end)
end

---@param pos table|nil
---@param box table|nil
---@return boolean
local function hitScreenBox(pos, box)
    if not pos or not box then
        return false
    end
    local pad = math.max(8, math.floor((box.h or 0) * 0.5))
    return pos.x >= box.x and pos.x <= box.x + box.w
        and pos.y >= box.y - pad and pos.y <= box.y + box.h + 2
end

--- 丢弃当前页缓存并重绘阅读视图（实体增删改或开关变化后调用）。
function Marks.invalidate()
    Marks._revision = Marks._revision + 1
    Marks._entity_cache_key = nil
    Marks._entity_cache = nil
    resetMarks(Marks)
    if Marks.ui and Marks.ui.dialog then
        UIManager:setDirty(Marks.ui.dialog, "ui")
    end
    if Marks.view then
        UIManager:setDirty(Marks.view, "ui")
    end
end

--- 当前视口变化时排一次页内扫描；绘制路径自身不执行文本搜索。
function Marks:rebuild()
    if not self.ui or not Marks.enabled() then
        resetMarks(self)
        return
    end
    local key = renderKey(self.ui)
    if not key then
        resetMarks(self)
        return
    end
    if key == self._render_key or key == self._scan_pending then
        return
    end
    local entities = loadEntities()
    self._marks = {}
    self._render_key = nil
    scheduleScan(self, key, entities)
end

---@param bb any
---@param rect table
local function paintDashedUnderscore(bb, rect)
    local Blitbuffer = require("ffi/blitbuffer")
    local Size = require("ui/size")
    local color = Blitbuffer.COLOR_DARK_GRAY
    local line_y = rect.y + rect.h - 1
    local x0 = rect.x
    local x1 = x0 + rect.w
    for i = x0, x1 - 8, 10 do
        bb:paintRect(i, line_y, 6, Size.line.thick, color)
    end
end

--- 作为 view module 被调用：先刷新标记框，再给每个命中画虚线下划线。
---@param bb any Blitbuffer
function Marks:paintTo(bb)
    if not Marks.enabled() then
        return
    end
    self:rebuild()
    for index, mark in ipairs(self._marks) do
        paintDashedUnderscore(bb, mark.box)
    end
end

---@param ges table
---@return boolean
function Marks:onTap(ges)
    if not Marks.enabled() or not self.ui then
        return false
    end
    if not ges or not ges.pos then
        return false
    end
    self:rebuild()
    for index, mark in ipairs(self._marks) do
        if hitScreenBox(ges.pos, mark.box) then
            require("xray.ui").showEntity(mark.entity)
            return true
        end
    end
    return false
end

--- 注册全屏 tap 区（只装一次）：命中实体才消费，否则让翻页/菜单等原有手势继续。
---@param ui table ReaderUI
local function registerTouch(ui)
    if ui._book_xray_marks_touch then
        return
    end
    ui._book_xray_marks_touch = true
    ui:registerTouchZones({ {
        id = "book_xray_entity_tap",
        ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        overrides = {
            "tap_forward",
            "tap_backward",
            "readerfooter_tap",
            "readermenu_tap",
        },
        handler = function(ges)
            return Marks:onTap(ges)
        end,
    } })
end

--- 往划词菜单加「X-Ray 查询」（只装一次）；总开关关闭时该项不显示。
---@param ui table ReaderUI
local function registerHighlight(ui)
    if not ui.highlight or ui._book_xray_highlight then
        return
    end
    ui._book_xray_highlight = true
    ui.highlight:addToHighlightDialog("12_xray_lookup", function(this)
        return {
            text = _("X-Ray 查询"),
            show_in_highlight_dialog_func = function()
                return require("utils.settings").get().book_xray_enabled ~= false
            end,
            callback = function()
                local word = require("util").cleanupSelectedText(this.selected_text.text)
                require("xray.ui").lookup(this.ui, word)
                this:onClose(true)
            end,
        }
    end)
end

--- 挂载页内标记、点击与划词 X-Ray。
---@param ui table
function Marks.install(ui)
    if not ui or ui._book_xray_marks then
        return
    end
    ui._book_xray_marks = true
    Marks._scan_pending = nil
    Marks.ui = ui
    if ui.view and ui.view.registerViewModule then
        ui.view:registerViewModule("book_xray_marks", Marks)
    end
    registerTouch(ui)
    registerHighlight(ui)
end

return Marks
