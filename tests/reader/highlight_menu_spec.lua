---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- reader.highlight_menu：划词按钮显隐门控、来源扫描与排序。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/widget/buttondialog"] = function() return {} end

local settings = {
    reader_popup_buttons = { dictionary = false, qrcode = false },
    reader_popup_button_order = { "translate", "dictionary" },
    reader_popup_seen = {},
}
local saves = 0
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function(owner)
            Assert.eq(owner, "reader")
            saves = saves + 1
        end,
    }
end

local factories = {
    ["06_dictionary"] = function()
        return { text = "Dictionary" }
    end,
    ["12_generate_qr_code"] = function()
        return { text = "Generate QR code" }
    end,
}

-- ReaderHighlight 类 stub 带原生 onHold / onHoldRelease：补丁要包它们，
-- 装上时就看得见原生方法，不用像别的补丁那样等补丁装完再摆回来。
local hold_returns = true
local ReaderHighlight = {
    onHold = function(self, arg, ges)
        self.hold_arg = { arg = arg, ges = ges }
        return hold_returns
    end,
    onHoldRelease = function(self)
        return "native"
    end,
}
package.preload["apps/reader/modules/readerhighlight"] = function() return ReaderHighlight end

-- highlight 实例经 __index 走类 stub：self.selected_text / self:onHoldRelease() 都在类上。
local highlight = setmetatable({ _highlight_buttons = factories }, { __index = ReaderHighlight })
local ui = { highlight = highlight }

local HighlightMenu = require("reader.highlight_menu")
HighlightMenu.ensureWrapped(highlight)

local dict = highlight._highlight_buttons["06_dictionary"]({}, nil)
Assert.is_false(dict.show_in_highlight_dialog_func())

local qr = highlight._highlight_buttons["12_generate_qr_code"]({}, nil)
Assert.is_false(qr.show_in_highlight_dialog_func())

settings.reader_popup_buttons.dictionary = true
Assert.is_true(dict.show_in_highlight_dialog_func())

HighlightMenu.ensureWrapped(highlight)
local dict2 = highlight._highlight_buttons["06_dictionary"]({}, nil)
Assert.is_true(dict2.show_in_highlight_dialog_func())

factories["07_translate"] = function() return { text = "Translate" } end
HighlightMenu.ensureWrapped(highlight)
local ordered = HighlightMenu.orderedFactories(highlight)
Assert.eq(ordered[1].index, "07_translate")
Assert.eq(ordered[2].index, "06_dictionary")

-- 来源：按工厂函数所在文件判断
local function defined_in(path)
    return load("return function() return { text = 'x' } end", "@" .. path)()
end
Assert.eq(HighlightMenu.originOf(defined_in("/mnt/us/koreader/plugins/qrclipboard.koplugin/main.lua")), "plugin:qrclipboard")
Assert.eq(HighlightMenu.originOf(defined_in("/mnt/us/koreader/plugins/book.koplugin/features/ai/explain.lua")), "book")
Assert.eq(HighlightMenu.originOf(defined_in("frontend/apps/reader/modules/readerhighlight.lua")), "koreader")
Assert.eq(HighlightMenu.originOf(defined_in("/mnt/us/koreader/patches/2-my-button.lua")), "patch:2-my-button")
Assert.eq(HighlightMenu.originOf(defined_in("somewhere.lua")), "unknown")

-- 未登记的按钮也受控：扫描记下来源，设置项 id 就是原键，可单独屏蔽
local saves_before = saves
factories["12_0_make_handmade_toc_item"] = defined_in("frontend/apps/reader/modules/readerhandmade.lua")
HighlightMenu.ensureWrapped(highlight)
Assert.eq(settings.reader_popup_seen["12_0_make_handmade_toc_item"].origin, "koreader")
Assert.eq(settings.reader_popup_seen.translate.origin, "unknown", "登记过的按钮按设置项 id 记")
Assert.is_true(saves > saves_before)
local toc_button = highlight._highlight_buttons["12_0_make_handmade_toc_item"]({}, nil)
Assert.is_true(toc_button.show_in_highlight_dialog_func())
settings.reader_popup_buttons["12_0_make_handmade_toc_item"] = false
Assert.is_false(toc_button.show_in_highlight_dialog_func())

-- 再扫一遍不重复包装、来源没变不落盘
saves_before = saves
local wrapped_toc = highlight._highlight_buttons["12_0_make_handmade_toc_item"]
HighlightMenu.ensureWrapped(highlight)
Assert.eq(highlight._highlight_buttons["12_0_make_handmade_toc_item"], wrapped_toc)
Assert.eq(saves, saves_before)

-- 原生移除后用同一个键重新注册：新工厂也要挂上门控
factories["12_0_make_handmade_toc_item"] = defined_in("frontend/apps/reader/modules/readerhandmade.lua")
HighlightMenu.ensureWrapped(highlight)
Assert.is_false(highlight._highlight_buttons["12_0_make_handmade_toc_item"]({}, nil).show_in_highlight_dialog_func())

-- 扫描到的按钮进排序：排在内置默认顺序之后
local order = HighlightMenu.order()
Assert.eq(order[#order], "12_0_make_handmade_toc_item")

-- 弹窗时已注册的就是全部：卸掉的插件按钮从设置页消失，显隐设置保留
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) o.movable = { dimen = {} } return o end }
end
package.preload["reader.selection"] = function()
    return { enabled = function() return false end, attach = function() return true end }
end
package.loaded["ui/widget/buttondialog"] = nil
HighlightMenu.install(nil)
settings.reader_popup_seen["12_gone_plugin"] = { title = "Gone", origin = "plugin:gone" }
-- 用户调过顺序：保存的顺序里也有它
local saved_order = HighlightMenu.order()
settings.reader_popup_button_order = saved_order
Assert.is_true(table.concat(saved_order, ","):find("12_gone_plugin", 1, true) ~= nil)
highlight.selected_text = { text = "x" }
ReaderHighlight.onShowHighlightMenu(highlight)
Assert.is_nil(settings.reader_popup_seen["12_gone_plugin"])
Assert.is_nil(table.concat(HighlightMenu.order(), ","):find("12_gone_plugin", 1, true),
    "保存的顺序里还有，也不再列出")
Assert.eq(settings.reader_popup_button_order, saved_order, "保存的顺序不动")
Assert.not_nil(settings.reader_popup_seen["12_0_make_handmade_toc_item"])
Assert.is_false(settings.reader_popup_buttons["12_0_make_handmade_toc_item"], "显隐设置不动")
Assert.not_nil(highlight.highlight_dialog)
Assert.is_nil(highlight.highlight_dialog._added_widgets)

-- 按住起手即画高亮：原生选词后 getWordFromPosition 不给盒子，temp[page] 会是 nil，
-- 高亮不画，看着像没反应，要等滑动才显形。这里补算盒子落进 temp 并刷选区。
local dirty = {}
package.loaded["ui/uimanager"] = nil
package.preload["ui/uimanager"] = function()
    local UIManager = {}
    function UIManager:show() end
    function UIManager:setDirty(widget, mode)
        dirty[#dirty + 1] = mode
    end
    function UIManager:close() end
    return UIManager
end
local attach_calls = 0
package.loaded["reader.selection"] = nil
package.preload["reader.selection"] = function()
    return {
        enabled = function() return false end,
        attach = function() attach_calls = attach_calls + 1 return true end,
        screenBoxes = function() return nil end,
    }
end
package.loaded["ui.guard"] = nil
local guard_isolated = false
package.preload["ui.guard"] = function()
    return {
        wrap = function(_label, fn) return fn end,
        call = function(_label, fn)
            if guard_isolated then return end
            fn()
        end,
    }
end

-- 情形一：原生给了盒子 —— 只要把 temp 落好并刷屏，不另算。
local doc_boxes_calls = 0
highlight.highlight_dialog = nil -- 划词菜单留下的；按住不弹自己弹的窗
highlight.ui = {
    paging = true,
    document = {
        getScreenBoxesFromPositions = function()
            doc_boxes_calls = doc_boxes_calls + 1
            return { { x = 10, y = 20, w = 30, h = 12 } }
        end,
    },
    view = {
        highlight = { temp = {} },
    },
}
-- ReaderHighlight 实例自身的 view（真实 KOReader 里就是 ui.view）
highlight.view = highlight.ui.view
highlight.selected_text = {
    text = "Mina", pos0 = { page = 7 }, pos1 = { page = 7 },
    sboxes = { { x = 1, y = 2, w = 3, h = 4 } },
}
hold_returns = true
dirty = {}
ReaderHighlight.onHold(highlight)
Assert.eq(highlight.ui.view.highlight.temp[7], highlight.selected_text.sboxes, "原生给了盒就照用")
Assert.eq(doc_boxes_calls, 0, "有盒不补算")
Assert.len(dirty, 1, "补刷一次选区")
Assert.eq(dirty[1], "ui")
Assert.is_nil(highlight.highlight_dialog, "按住不弹菜单")

-- 情形二：原生没给盒子 —— 按 pos0/pos1 补算，落进 temp，高亮当场画出来。
highlight.selected_text = { text = "Mina", pos0 = { page = 3 }, pos1 = { page = 3 } }
dirty = {}
ReaderHighlight.onHold(highlight)
Assert.eq(doc_boxes_calls, 1, "没盒才补算")
Assert.len(highlight.ui.view.highlight.temp[3], 1, "补算的盒落进 temp")
Assert.eq(highlight.selected_text.sboxes[1].x, 10, "sboxes 回填，菜单锚点也准")
Assert.len(dirty, 1, "补刷一次选区")

-- 情形三：补算也拿不到 —— 不画也不崩，松手菜单照旧。
highlight.selected_text = { text = "Mina", pos0 = { page = 5 }, pos1 = { page = 5 } }
highlight.ui.document.getScreenBoxesFromPositions = nil
dirty = {}
ReaderHighlight.onHold(highlight)
Assert.is_nil(highlight.ui.view.highlight.temp[5], "拿不到盒不写 nil 覆盖")
Assert.len(dirty, 0, "没盒不刷")
Assert.eq(ReaderHighlight.onHoldRelease(highlight), "native", "松手仍走原生，不拦")

-- 情形四：原生没接住（按在图片 / 页外 / 长按压成"什么都不做"）—— 完全不碰。
local before_text = highlight.selected_text
highlight.selected_text = nil
hold_returns = false
Assert.is_false(ReaderHighlight.onHold(highlight))
Assert.is_nil(highlight.selected_text, "没选上不自己选")
Assert.len(dirty, 0, "没选上不刷")
hold_returns = true
highlight.selected_text = before_text

-- 补算抛错只隔离，不影响原生起手返回值。
local orig_boxes = highlight.ui.document.getScreenBoxesFromPositions
highlight.ui.document.getScreenBoxesFromPositions = function() error("boom") end
guard_isolated = true -- guard 隔离：这段里出错静默，不当成没处理
Assert.is_true(ReaderHighlight.onHold(highlight))
highlight.ui.document.getScreenBoxesFromPositions = orig_boxes
guard_isolated = false
