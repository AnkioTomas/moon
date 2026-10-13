--[[--
页内 X-Ray 实体标记：已入库人物 / 地点 / 专有名词虚线下划线，点击弹出详情。

@module koplugin.book.features.xray.marks
--]]

require("l10n").apply()

local PageMarks = require("reader.page_marks")
local Text = require("utils.text")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")
local _ = require("gettext")

local SCAN_DEBOUNCE = 0.2

local Marks = {
    view = nil,
    ui = nil,
    _marks = {},
    _render_key = nil,
    _revision = 0,
    _scan_pending = nil,
    _scan_timer = nil,
    _scan_job = nil,
    _scan_token = nil,
    _entity_cache_key = nil,
    _entity_cache = nil,
}

--- 页内实体标记是否开启。
---@return boolean
function Marks.enabled()
    local settings = require("utils.settings").get("features.xray")
    return settings.book_xray_enabled and settings.book_xray_show_marks
end

--- 开关页内实体标记并刷新当前阅读视图。
---@param on boolean|nil
---@param ui table|nil
function Marks.setEnabled(on, ui)
    local MoonSettings = require("utils.settings")
    local settings = MoonSettings.get("features.xray")
    settings.book_xray_show_marks = on ~= false
    MoonSettings.save("features.xray", settings)
    Marks.invalidate()
    ui = ui or Marks.ui
    if ui and ui.dialog then
        UIManager:setDirty(ui.dialog, "ui")
    end
end

---@return table[]
local function loadEntities()
    local cur = require("reader.session").current()
    local identity = cur and cur.identity
    if not identity then
        return {}
    end
    local key = identity.source_id .. "\0" .. identity.stable_id
        .. "\0" .. tostring(Marks._revision)
    if Marks._entity_cache_key ~= key then
        Marks._entity_cache_key = key
        Marks._entity_cache = require("features.xray.db").list(identity.source_id, identity.stable_id)
    end
    return Marks._entity_cache
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

---@param s string
---@return string
local function squash(s)
    return (s:lower():gsub("%s+", ""))
end

--- 用一次取到的屏幕文字粗筛名字，只让真正出现的名字去做逐个定位；
--- 去空白比较，兼容 PDF 词框按空格拼接的中文。取不到文字时不筛。
---@param names table[]
---@param text string|nil
---@return table[]
local function namesOnScreen(names, text)
    if not text then return names end
    local haystack = squash(text)
    local out = {}
    for index, item in ipairs(names) do
        if haystack:find(squash(item.name), 1, true) then
            out[#out + 1] = item
        end
    end
    return out
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
    local width, height = PageMarks.screenSize(ui)
    local out = {}

    local function addMark(entity, box)
        out[#out + 1] = {
            entity = entity,
            box = { x = box.x, y = box.y, w = box.w, h = box.h },
        }
    end

    local page = PageMarks.currentPage(ui)
    local names = namesOnScreen(collectNames(entities), require("features.xray.context").visibleText(ui, page))
    if document.getScreenBoxesFromPositions and document.findText then
        for _idx, item in ipairs(names) do
            -- CRE 的 findText 只搜索当前视口附近有限高度；结果仍按屏幕相交严格裁剪。
            local ok, matches = pcall(document.findText, document,
                item.name, 0, 0, true, nil, false, 5000, 0)
            if ok and matches then
                for _idx, match in ipairs(matches) do
                    local start_xp = match and match.start
                    local end_xp = match and match["end"]
                    if start_xp and end_xp then
                        local boxes_ok, boxes = pcall(document.getScreenBoxesFromPositions,
                            document, start_xp, end_xp, true)
                        if boxes_ok and boxes then
                            for _idx, box in ipairs(boxes) do
                                if PageMarks.intersects(box, width, height) then
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

    local kopt = document.koptinterface
    if page < 1 or not kopt or not kopt.findAllMatches then
        return out
    end
    for _idx, item in ipairs(names) do
        local ok, boxes = pcall(kopt.findAllMatches, kopt, document, item.name, true, page)
        if ok and boxes then
            for _idx, page_box in ipairs(boxes) do
                local screen_box = page_box
                local view = ui.view
                if view and view.pageToScreenTransform then
                    local transformed_ok, transformed = pcall(
                        view.pageToScreenTransform, view, page, page_box)
                    screen_box = transformed_ok and transformed or nil
                end
                if screen_box and PageMarks.intersects(screen_box, width, height) then
                    addMark(item.entity, screen_box)
                end
            end
        end
    end
    return out
end

--- 取消待执行的扫描计时器与正在运行的扫描 Job。
---@param self table
local function cancelScan(self)
    if self._scan_timer then
        UIManager:unschedule(self._scan_timer)
        self._scan_timer = nil
    end
    if self._scan_job then
        self._scan_job:cancel()
        self._scan_job = nil
    end
end

--- 清空当前屏幕标记并取消待执行或正在运行的扫描。
---@param self table
local function resetMarks(self)
    self._scan_token = nil
    cancelScan(self)
    self._marks = {}
    self._render_key = nil
    self._scan_pending = nil
end

--- 当前视口缓存键：身份 + 实体修订号 + 屏幕尺寸 + 实时页码/滚动位置。
---@param ui table
---@return string|nil 无阅读会话时 nil
local function renderKey(ui)
    return PageMarks.viewKey(ui, Marks._revision)
end

--- 防抖后在子进程扫描当前页；快速翻页会取消旧计时器或旧 Job。
---@param self table
---@param key string
---@param entities table[]
local function scheduleScan(self, key, entities)
    if self._scan_pending == key then
        return
    end
    cancelScan(self)
    self._scan_pending = key
    local ui = self.ui
    local token = {}
    self._scan_token = token
    local timer
    timer = require("ui.guard").wrap("xray scan", function()
        if self._scan_token ~= token or self._scan_pending ~= key or self.ui ~= ui then
            return
        end
        self._scan_timer = nil
        if not Marks.enabled() or renderKey(ui) ~= key then
            if self._scan_pending == key then self._scan_pending = nil end
            return
        end
        local job = require("workers.job").run(function()
            return scanVisibleMarks(ui, entities)
        end, {
            name = "features.xray.marks",
            kind = "light",
            timeout = 30,
            on_done = function(marks)
                if self._scan_token ~= token or self._scan_pending ~= key
                    or self.ui ~= ui or not Marks.enabled() or renderKey(ui) ~= key then
                    return
                end
                self._scan_job = nil
                self._scan_pending = nil
                self._marks = marks or {}
                self._render_key = key
                -- updateView 排扫描前已清空标记并随翻页画过一次，空结果无需再整页刷新。
                if ui.dialog and #self._marks > 0 then
                    UIManager:setDirty(ui.dialog, "ui")
                end
            end,
            on_failed = function(err)
                if self._scan_token ~= token then return end
                self._scan_job = nil
                self._scan_pending = nil
                self._marks = {}
                self._render_key = key
                logger.warn("book.xray marks scan failed", err)
            end,
        })
        if self._scan_token == token and not job.settled then
            self._scan_job = job
        end
    end)
    self._scan_timer = timer
    UIManager:scheduleIn(SCAN_DEBOUNCE, timer)
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
function Marks:updateView()
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

--- 标记图层：刷新视口后交出屏上实体（点按弹详情）。
---@return PageMark[]
function Marks:marks()
    if not Marks.enabled() then
        return {}
    end
    self:updateView()
    local solid = require("utils.settings").get("features.xray").book_xray_mark_style == "solid"
    local out = {}
    for _idx, mark in ipairs(self._marks) do
        out[#out + 1] = {
            boxes = { mark.box },
            solid = solid,
            tap = function() require("features.xray.ui").showEntity(mark.entity) end,
        }
    end
    return out
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
                return require("utils.settings").get("features.xray").book_xray_enabled
            end,
            callback = require("ui.guard").wrap("xray lookup", function()
                local word = require("util").cleanupSelectedText(this.selected_text.text)
                require("features.xray.ui").lookup(this.ui, word)
                this:onClose(true)
            end),
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
    resetMarks(Marks)
    Marks.ui = ui
    -- 实体只占一个词，先于段评（priority 20）占位，长句段评在实体处让出。
    PageMarks.add(ui, "xray", 10, Marks)
    registerHighlight(ui)
end

return Marks
