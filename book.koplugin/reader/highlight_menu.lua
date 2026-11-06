--[[--
划词工具栏：复用 KOReader 原生 ButtonDialog，按 Book 设置裁剪、排序并五列排版。

按钮工厂、回调、锚点和关闭行为全部保持原生；这里只接管收集和分行。
所有已注册按钮（KOReader 自带、其它插件、用户补丁、本插件）都受显隐与排序设置控制：
弹窗时扫描到的按钮记进 `reader_popup_seen`（设置键 → { title, origin }），设置页据此列出。

按住起手还要补一次高亮：原生长按选词后把 `selected_text.sboxes` 直接赋给
`view.highlight.temp`，而 `getWordFromPosition` 并不保证给盒子（原生注释只对
crengine 作保）。盒子是 nil 时高亮就不画，看着像"没反应"，要等滑动走了
range 那条路才显形。这里在按住起手后补算盒子、落进 temp 并刷选区，
按下即见所选。菜单仍按原生时机弹，不提前弹。

@module koplugin.book.reader.highlight_menu
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")
local Ext = require("utils.extension")
local _ = require("gettext")

---@class BookReaderHighlightMenu
local HighlightMenu = {}

local TOOLBAR_COLUMNS = 5

--- ReaderHighlight._highlight_buttons 键 → 设置项 id；不在表里的按钮直接用原键作设置项 id。
---@type table<string, string>
local INDEX_TO_KEY = {
    ["01_select"] = "select",
    ["02_highlight"] = "highlight",
    ["03_copy"] = "copy",
    ["04_add_note"] = "add_note",
    ["05_wikipedia"] = "wikipedia",
    ["06_dictionary"] = "dictionary",
    ["07_translate"] = "translate",
    ["09_view_html"] = "view_html",
    ["12_generate_qr_code"] = "qrcode",
    ["12_search"] = "search",
    ["12_xray_lookup"] = "xray",
    ["12_ai_explain"] = "ai_explain",
}

local OWN_PLUGIN = debug.getinfo(1, "S").source:match("([^/]+)%.koplugin/")

---@param index string
---@return string
local function keyOf(index)
    return INDEX_TO_KEY[index] or index
end

--- 按钮工厂定义在哪：`book`（本插件）、`koreader`、`plugin:<目录名>`、`patch:<文件名>`、`unknown`。
---@param factory function
---@return string
function HighlightMenu.originOf(factory)
    local source = debug.getinfo(factory, "S").source
    local plugin = source:match("([^/]+)%.koplugin/")
    if plugin then
        return plugin == OWN_PLUGIN and "book" or "plugin:" .. plugin
    end
    local patch = source:match("patches/([^/]+)%.lua$")
    if patch then return "patch:" .. patch end
    if source:find("frontend/", 1, true) then return "koreader" end
    return "unknown"
end

--- 记下扫描到的按钮字段，有变化才落盘。
---@param key string
---@param field "title"|"origin"
---@param value string
local function remember(key, field, value)
    local reader = MoonSettings.get("reader")
    local entry = reader.reader_popup_seen[key]
    if not entry then
        entry = {}
        reader.reader_popup_seen[key] = entry
    end
    if entry[field] == value then return end
    entry[field] = value
    MoonSettings.save("reader")
end

--- 划词弹窗某项是否应在菜单中显示。
---@param key string
---@return boolean
function HighlightMenu.isEnabled(key)
    return MoonSettings.get("reader").reader_popup_buttons[key] ~= false
end

--- 合并用户顺序、内置默认顺序与扫描到的按钮，旧配置或重复项不会让按钮消失。
--- 用户顺序里既非内置、又已被 forgetMissing 忘掉的键（卸掉的插件）不列出；期间没调过顺序的话，
--- 装回来重新扫到就照旧排回原位。
---@return string[]
function HighlightMenu.order()
    local reader = MoonSettings.get("reader")
    local defaults = require("reader.setting").defaults.reader_popup_button_order
    local builtin = {}
    for _idx, key in ipairs(defaults) do builtin[key] = true end
    local out, seen = {}, {}
    for _idx, key in ipairs(reader.reader_popup_button_order or {}) do
        if type(key) == "string" and not seen[key] and (builtin[key] or reader.reader_popup_seen[key]) then
            out[#out + 1], seen[key] = key, true
        end
    end
    for _idx, key in ipairs(defaults) do
        if not seen[key] then
            out[#out + 1], seen[key] = key, true
        end
    end
    local scanned = {}
    for key in pairs(reader.reader_popup_seen) do
        if not seen[key] then scanned[#scanned + 1] = key end
    end
    table.sort(scanned)
    for _idx, key in ipairs(scanned) do out[#out + 1] = key end
    return out
end

--- 按用户顺序列出当前已注册的工厂；未知插件按钮稳定地排在末尾。
---@param highlight table
---@return { index: string, factory: function }[]
function HighlightMenu.orderedFactories(highlight)
    local position = {}
    for i, key in ipairs(HighlightMenu.order()) do
        position[key] = i
    end
    local factories = {}
    for index, factory in pairs(highlight._highlight_buttons or {}) do
        factories[#factories + 1] = {
            index = index,
            factory = factory,
            position = position[keyOf(index)] or math.huge,
        }
    end
    table.sort(factories, function(a, b)
        if a.position ~= b.position then
            return a.position < b.position
        end
        return a.index < b.index
    end)
    return factories
end

---@param fn function
---@param key string
---@return function
local function wrapFactory(fn, key)
    return function(this, index)
        local button = fn(this, index)
        if not button then
            return button
        end
        -- 事件 id 保持不变；按钮行为被扩展接管时由它给新名字。
        for _idx, relabel in ipairs(Ext.list("highlight.relabel")) do
            local text = relabel(key)
            if text then
                button.text = text
                break
            end
        end
        local orig_show = button.show_in_highlight_dialog_func
        button.show_in_highlight_dialog_func = function()
            if not HighlightMenu.isEnabled(key) then
                return false
            end
            return not orig_show or orig_show()
        end
        return button
    end
end

--- 给当前 ReaderHighlight 实例的全部按钮挂上显隐门控并记下来源（含晚注册、重新注册的按钮）。
---@param highlight table|nil
function HighlightMenu.ensureWrapped(highlight)
    if not highlight or not highlight._highlight_buttons then
        return
    end
    -- 按工厂函数而非键记：原生自定义目录开关时会移除再注册同一个键。
    highlight._book_popup_wrapped = highlight._book_popup_wrapped or {}
    local wrapped = highlight._book_popup_wrapped
    for idx, factory in pairs(highlight._highlight_buttons) do
        if not wrapped[factory] then
            local key = keyOf(idx)
            remember(key, "origin", HighlightMenu.originOf(factory))
            local wrapper = wrapFactory(factory, key)
            wrapped[wrapper] = true
            highlight._highlight_buttons[idx] = wrapper
        end
    end
end

--- 弹窗时已注册的按钮就是全部：卸掉的插件、删掉的补丁不再留在设置页。显隐与顺序设置不动，装回来照旧生效。
---@param highlight table ReaderHighlight
local function forgetMissing(highlight)
    local present = {}
    for idx in pairs(highlight._highlight_buttons) do present[keyOf(idx)] = true end
    local reader = MoonSettings.get("reader")
    local changed = false
    for key in pairs(reader.reader_popup_seen) do
        if not present[key] then
            reader.reader_popup_seen[key] = nil
            changed = true
        end
    end
    if changed then MoonSettings.save("reader") end
end

--- 在 ReaderHighlight 类上挂一次钩子，弹窗前补齐按钮门控。
--- 必须在弹窗时机而非安装时机包装，因为别的插件会晚注册按钮；类级标记保证只打一次补丁。
local function patchShowMenu()
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    if ReaderHighlight._book_popup_patched then
        return
    end
    ReaderHighlight._book_popup_patched = true
    --- 原生实现把 columns 写死为 2。保留其余生命周期，仅改为工具栏五列与可配顺序。
    ---@param self table ReaderHighlight
    ---@param index number|nil 已有标注的序号；新划词为 nil
    local function showMenu(self, index)
        HighlightMenu.ensureWrapped(self)
        if not self.selected_text then
            return
        end
        -- 扫描页选区没有文字层：先 OCR，按钮才拿得到文字；识别不出来就提示并不弹菜单。
        local fill = Ext.last("highlight.fill_selection")
        if fill and not fill(self) then
            return
        end
        forgetMissing(self)
        local ButtonDialog = require("ui/widget/buttondialog")
        local UIManager = require("ui/uimanager")
        local buttons = { {} }
        for _idx, item in ipairs(HighlightMenu.orderedFactories(self)) do
            local button = item.factory(self, index)
            local title = button.text or button.text_func and button.text_func()
            if title then remember(keyOf(item.index), "title", title) end
            if not button.show_in_highlight_dialog_func or button.show_in_highlight_dialog_func() then
                if #buttons[#buttons] >= TOOLBAR_COLUMNS then
                    buttons[#buttons + 1] = {}
                end
                buttons[#buttons][#buttons[#buttons] + 1] = button
            end
        end
        self.highlight_dialog = ButtonDialog:new{
            buttons = buttons,
            anchor = function()
                local Selection = require("reader.selection")
                if not index and Selection.enabled() then
                    local placed, pop_down = Selection.menuAnchorFor(self, self.highlight_dialog)
                    if placed then
                        return placed, pop_down
                    end
                end
                return self:_getDialogAnchor(self.highlight_dialog, index)
            end,
            tap_close_callback = function()
                if self.hold_pos then
                    self:clear()
                end
            end,
        }
        local dialog = self.highlight_dialog
        -- 原生 "[ui]" 不带区域 = 整屏刷新；这里只刷菜单自身，"[ui]" 仍禁止合并（Sage 内核 alpha 混合 bug）。
        UIManager:show(dialog, function()
            return "[ui]", dialog.movable.dimen
        end)
        -- 没挂手柄时选区可能刚变（原生 extendSelection 不自刷），按原生刷整屏。
        if not require("reader.selection").attach(self, index) then
            UIManager:setDirty(nil, "[ui]")
        end
        return true
    end
    ReaderHighlight.onShowHighlightMenu = require("ui.guard").wrap("highlight menu", showMenu)
end

--- 选区首尾的屏幕盒。没有屏幕盒（或拿不到）返回 nil。
--- 只用 `sboxes`：它是屏幕坐标，`view.highlight.temp` 要的正是屏幕盒。
--- `pboxes` 是页面坐标（KOPT 的 pbox 与 sbox 明确分开），Kindle/KOPT 文档
--- 常只有 pboxes；拿页面坐标当屏幕盒会画错位置，还会让调用方以为"有盒"而跳过
--- `getScreenBoxesFromPositions` 的现算。所以这里不回退 pboxes：
--- 没有 sboxes 就返回 nil，交给调用方按 pos0/pos1 现算，拿不到就不画。
---@param selected table selected_text
---@return table[]|nil
local function selectedBoxes(selected)
    local boxes = selected.sboxes
    if boxes and #boxes > 0 then
        return boxes
    end
end

--- 按住起手就把高亮画出来。
--- 原生把 `selected_text.sboxes` 直接赋给 `view.highlight.temp`，
--- 而 `getWordFromPosition` 不保证给盒子（原生注释只对 crengine 作保）：
--- 盒子是 nil 时 `temp[page] = nil`，高亮不画，看着像"没反应"，
--- 要等滑动走了 range 那条路才显形。这里补算盒子、落进 temp 再刷选区。
--- 菜单、手柄都不动：仍按原生时机（松手弹菜单）走。
local function patchHoldMenu()
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    if ReaderHighlight._book_hold_highlight_patched then
        return
    end
    ReaderHighlight._book_hold_highlight_patched = true

    local orig_on_hold = ReaderHighlight.onHold
    function ReaderHighlight:onHold(arg, ges)
        local handled = orig_on_hold(self, arg, ges)
        -- 只在原生选上了词时补：按在图片 / 页外 / 长按压成"什么都不做"不碰。
        if not handled or not self.selected_text then
            return handled
        end
        require("ui.guard").call("highlight hold", function()
            local document = self.ui and self.ui.document
            local selected = self.selected_text
            local boxes = selectedBoxes(selected)
            if not boxes and document and document.getScreenBoxesFromPositions
                and selected.pos0 and selected.pos1 then
                -- 与 selection.lua 的 charRange 同一思路：引擎不给盒就按两端坐标算。
                local ok, computed = pcall(document.getScreenBoxesFromPositions,
                    document, selected.pos0, selected.pos1, true)
                if ok and computed and #computed > 0 then
                    boxes = computed
                    selected.sboxes = computed
                end
            end
            if not boxes then
                return
            end
            -- paging 模式高亮画在 view.highlight.temp 上；滚动模式 crengine 自己画选区。
            if self.ui and self.ui.paging and self.view and self.view.highlight then
                local page = selected.pos0 and selected.pos0.page
                if page then
                    self.view.highlight.temp[page] = boxes
                end
            end
            require("ui/uimanager"):setDirty(self.dialog, "ui")
        end)
        return handled
    end
end

--- 安装划词弹窗显隐门控；重复调用无副作用。
---@param ui table|nil
function HighlightMenu.install(ui)
    patchShowMenu()
    patchHoldMenu()
    if not ui or not ui.highlight then
        return
    end
    HighlightMenu.ensureWrapped(ui.highlight)
    -- Reader.onCreate 在 ReaderReady 事件内执行，此时 postInitCallback 已被清空。
    if ui.registerPostReaderReadyCallback then
        ui:registerPostReaderReadyCallback(function()
            HighlightMenu.ensureWrapped(ui.highlight)
        end)
    end
end

return HighlightMenu
