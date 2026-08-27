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
    _matches = {},
    _matches_key = nil,
    _marks = {},
    _render_key = nil,
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

---@param ui table
---@return table[]
local function loadEntities(ui)
    local cur = require("ui.reader.session").current()
    local identity = cur and cur.identity
    if not identity then
        return {}
    end
    return require("xray.store").loadEntities(identity)
end

local function entityStamp(entities)
    local stamp = 0
    for _, entity in ipairs(entities or {}) do
        stamp = math.max(stamp, tonumber(entity.updated_at) or 0)
    end
    return stamp
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

---@param ui table
---@return number
local function currentPage(ui)
    if ui and ui.getCurrentPage then
        local ok, page = pcall(ui.getCurrentPage, ui)
        if ok and page then return tonumber(page) or 0 end
    end
    if ui and ui.paging and ui.paging.getCurrentPage then
        return tonumber(ui.paging:getCurrentPage()) or 0
    end
    if ui and ui.rolling and ui.rolling.getCurrentPage then
        return tonumber(ui.rolling:getCurrentPage()) or 0
    end
    return 0
end

--- 滚动文档（CreDocument）与分页文档（PDF/DJVU）的 findAllText 签名不同。
---@param document table
---@param is_reflow boolean
---@param text string
---@param max_hits integer
---@return table|nil
local function findMatches(document, is_reflow, text, max_hits)
    if not document or not document.findAllText then
        return nil
    end
    if is_reflow then
        local ok, matches = pcall(document.findAllText, document, text, true, 0, max_hits, false)
        return ok and matches or nil
    end
    local ok, matches = pcall(document.findAllText, document, text, true, 0, max_hits)
    return ok and matches or nil
end

--- 用 findAllText 一次扫出整本书里实体名/别名的所有出现位置。
---@param ui table
---@param entities table[]
---@return table[]
local function buildMatches(ui, entities)
    local document = ui and ui.document
    if not document or not document.findAllText then
        return {}
    end
    local is_reflow = document.getScreenBoxesFromPositions ~= nil
    local max_hits = 5000
    local names = {}
    local seen = {}
    for _, entity in ipairs(entities or {}) do
        local candidates = { entity.name }
        for _, alias in ipairs(entity.aliases or {}) do
            candidates[#candidates + 1] = alias
        end
        for _, name in ipairs(candidates) do
            name = Text.trim(name)
            if name ~= "" and not seen[name:lower()] then
                seen[name:lower()] = true
                names[#names + 1] = { name = name, entity = entity }
            end
        end
    end

    local out = {}
    for _, item in ipairs(names) do
        local matches = findMatches(document, is_reflow, item.name, max_hits)
        if matches then
            for _, match in ipairs(matches) do
                out[#out + 1] = { entity = item.entity, match = match }
            end
        end
    end
    return out
end

--- 把 xpointer / page boxes 匹配解析成当前屏幕上的框。
---@param ui table
---@param matches table[]
---@return table[]
local function resolveMarks(ui, matches)
    local document = ui and ui.document
    if not document then
        return {}
    end
    local is_reflow = document.getScreenBoxesFromPositions ~= nil
    local width, height = screenSize(ui)
    local out = {}

    for _, item in ipairs(matches) do
        local match = item.match
        local entity = item.entity
        if is_reflow then
            local start_xp = match and match.start
            local end_xp = match and match["end"]
            if start_xp and end_xp then
                local ok, boxes = pcall(document.getScreenBoxesFromPositions, document, start_xp, end_xp, true)
                if ok and boxes then
                    for _, box in ipairs(boxes) do
                        if type(box) == "table" and box.x and box.y and box.w and box.h then
                            if (not height or (box.y >= 0 and box.y < height))
                                and (not width or (box.x >= 0 and box.x < width)) then
                                out[#out + 1] = {
                                    entity = entity,
                                    box = { x = box.x, y = box.y, w = box.w, h = box.h },
                                }
                            end
                        end
                    end
                end
            end
        else
            local page = currentPage(ui)
            if match and match.start and match.start == page and match.boxes and page > 0 then
                for _, native in ipairs(match.boxes) do
                    local page_box = native
                    if document.nativeToPageRectTransform then
                        local ok, transformed = pcall(document.nativeToPageRectTransform, document, page, native)
                        if ok and transformed then
                            page_box = transformed
                        end
                    end
                    local view = ui.view
                    if view and view.pageToScreenTransform then
                        local ok, screen_box = pcall(view.pageToScreenTransform, view, page, page_box)
                        if ok and screen_box then
                            out[#out + 1] = {
                                entity = entity,
                                box = { x = screen_box.x, y = screen_box.y, w = screen_box.w, h = screen_box.h },
                            }
                        end
                    else
                        out[#out + 1] = {
                            entity = entity,
                            box = { x = page_box.x, y = page_box.y, w = page_box.w, h = page_box.h },
                        }
                    end
                end
            end
        end
    end
    return out
end

local function scanKey(ui, entities)
    local cur = require("ui.reader.session").current()
    if not cur or not cur.identity then
        return nil
    end
    return table.concat({
        cur.identity.source_id, cur.identity.stable_id,
        tostring(cur.identity.chapter_idx or 0), tostring(#entities), tostring(entityStamp(entities)),
    }, "\0")
end

local function renderKey(ui, entities)
    local key = scanKey(ui, entities)
    if not key then
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
        key, tostring(w or 0), tostring(h or 0),
        tostring(currentPage(ui)), pos,
    }, "\0")
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

function Marks.invalidate()
    Marks._matches = {}
    Marks._matches_key = nil
    Marks._marks = {}
    Marks._render_key = nil
    if Marks.ui and Marks.ui.dialog then
        UIManager:setDirty(Marks.ui.dialog, "ui")
    end
    if Marks.view then
        UIManager:setDirty(Marks.view, "ui")
    end
end

function Marks:rebuild()
    if not self.ui or not Marks.enabled() then
        self._marks = {}
        self._render_key = nil
        return
    end
    local entities = loadEntities(self.ui)
    local matches_key = scanKey(self.ui, entities)
    if not matches_key then
        self._matches = {}
        self._matches_key = nil
        self._marks = {}
        self._render_key = nil
        return
    end
    if matches_key ~= self._matches_key then
        self._matches = buildMatches(self.ui, entities)
        self._matches_key = matches_key
        self._render_key = nil
    end
    local r_key = renderKey(self.ui, entities)
    if r_key == self._render_key then
        return
    end
    self._render_key = r_key
    self._marks = resolveMarks(self.ui, self._matches)
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

function Marks:paintTo(bb, _x, _y)
    if not Marks.enabled() then
        return
    end
    self:rebuild()
    for _, mark in ipairs(self._marks) do
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
    for _, mark in ipairs(self._marks) do
        if hitScreenBox(ges.pos, mark.box) then
            require("xray.ui").showEntity(mark.entity)
            return true
        end
    end
    return false
end

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
    Marks.ui = ui
    if ui.view and ui.view.registerViewModule then
        ui.view:registerViewModule("book_xray_marks", Marks)
    end
    registerTouch(ui)
    registerHighlight(ui)
end

return Marks
