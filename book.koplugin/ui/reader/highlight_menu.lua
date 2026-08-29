--[[--
划词工具栏：复用 KOReader 原生 ButtonDialog，按 Book 设置裁剪、排序并五列排版。

按钮工厂、回调、锚点和关闭行为全部保持原生；这里只接管收集和分行，含
qrclipboard 的 12_generate_qr_code 与 Book 的 X-Ray 查询。

@module koplugin.book.ui.reader.highlight_menu
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")
local _ = require("gettext")

local HighlightMenu = {}

local TOOLBAR_COLUMNS = 5

--- ReaderHighlight._highlight_buttons 键 → 设置项 id
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
}

local DEFAULT_ORDER = {
    "select", "highlight", "copy", "add_note", "dictionary", "translate",
    "wikipedia", "xray", "search", "view_html", "qrcode",
}

--- 划词弹窗某项是否应在菜单中显示。
---@param key string
---@return boolean
function HighlightMenu.isEnabled(key)
    local buttons = MoonSettings.get().reader_popup_buttons
    if type(buttons) ~= "table" then
        return true
    end
    return buttons[key] ~= false
end

--- 合并用户顺序与新增按钮，旧配置或重复项不会让按钮消失。
---@return string[]
function HighlightMenu.order()
    local configured = MoonSettings.get("reader").reader_popup_button_order
    local out, seen = {}, {}
    for _, key in ipairs(configured or {}) do
        if type(key) == "string" and not seen[key] then
            out[#out + 1], seen[key] = key, true
        end
    end
    for _, key in ipairs(DEFAULT_ORDER) do
        if not seen[key] then
            out[#out + 1], seen[key] = key, true
        end
    end
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
            position = position[INDEX_TO_KEY[index]] or math.huge,
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
        if key == "wikipedia" and MoonSettings.get("reader").baike_enabled ~= false then
            -- 事件 id 保持不变，实际处理已由 baike.init 接管。
            button.text = _("百度百科")
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

--- 给当前 ReaderHighlight 实例挂上显隐门控（含晚注册的插件按钮）。
---@param highlight table|nil
---@return nil
function HighlightMenu.ensureWrapped(highlight)
    if not highlight or not highlight._highlight_buttons then
        return
    end
    highlight._book_popup_wrapped = highlight._book_popup_wrapped or {}
    for idx, factory in pairs(highlight._highlight_buttons) do
        if not highlight._book_popup_wrapped[idx] then
            local key = INDEX_TO_KEY[idx]
            if key then
                highlight._highlight_buttons[idx] = wrapFactory(factory, key)
            end
            highlight._book_popup_wrapped[idx] = true
        end
    end
end

--- 在 ReaderHighlight 类上挂一次钩子，弹窗前补齐按钮门控。
--- 必须在弹窗时机而非安装时机包装，因为别的插件会晚注册按钮；类级标记保证只打一次补丁。
local function patchShowMenu()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or ReaderHighlight._book_popup_patched then
        return
    end
    ReaderHighlight._book_popup_patched = true
    --- 原生实现把 columns 写死为 2。保留其余生命周期，仅改为工具栏五列与可配顺序。
    ---@param index number|nil 已有标注的序号；新划词为 nil
    ---@return boolean
    function ReaderHighlight:onShowHighlightMenu(index)
        HighlightMenu.ensureWrapped(self)
        if not self.selected_text then
            return
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        local UIManager = require("ui/uimanager")
        local buttons = { {} }
        for _, item in ipairs(HighlightMenu.orderedFactories(self)) do
            local button = item.factory(self, index)
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
                return self:_getDialogAnchor(self.highlight_dialog, index)
            end,
            tap_close_callback = function()
                if self.hold_pos then
                    self:clear()
                end
            end,
        }
        UIManager:show(self.highlight_dialog, "[ui]")
        return true
    end
end

--- 安装划词弹窗显隐门控；重复调用无副作用。
---@param ui table|nil
---@return nil
function HighlightMenu.install(ui)
    patchShowMenu()
    if not ui or not ui.highlight then
        return
    end
    HighlightMenu.ensureWrapped(ui.highlight)
    -- Reader.attach 在 ReaderReady 事件内执行，此时 postInitCallback 已被清空。
    if ui.registerPostReaderReadyCallback then
        ui:registerPostReaderReadyCallback(function()
            HighlightMenu.ensureWrapped(ui.highlight)
        end)
    end
end

return HighlightMenu
