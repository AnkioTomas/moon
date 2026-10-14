--[[-- features.ocr：扫描页选区先 OCR 再弹划词菜单；识别不出来提示并不弹。 --]]

local Assert = require("support.assert")

local prompts = 0
package.preload["features.ocr.ui"] = function()
    return { promptMissing = function() prompts = prompts + 1 end }
end
local Ocr = require("features.ocr")

-- 有文字层：不动。
local hl = { selected_text = { text = "已有" } }
Assert.is_true(Ocr.fillSelection(hl))
Assert.eq(hl.selected_text.text, "已有")

-- 扫描页：getOCRText 的结果写回 selected_text.text，菜单按钮都能拿到。
local doc = { getOCRText = function(_, page, boxes) return page == 3 and #boxes == 2 and "识别文字" or nil end }
hl = { ui = { document = doc }, hold_pos = { page = 3 }, selected_text = { text = "", sboxes = { {}, {} } } }
Assert.is_true(Ocr.fillSelection(hl))
Assert.eq(hl.selected_text.text, "识别文字")

-- getOCRText 为空：退回逐词 getOCRWord。
doc = {
    getOCRText = function() return "" end,
    getOCRWord = function(_, _page, w) return w.sbox.word end,
}
hl = { ui = { document = doc }, hold_pos = { page = 1 }, selected_text = { text = "", sboxes = { { word = "ab" }, { word = "cd" } } } }
Assert.is_true(Ocr.fillSelection(hl))
Assert.eq(hl.selected_text.text, "abcd")

-- 识别不出来：提示、清选区、不弹菜单。
local cleared = false
doc = { getOCRText = function() return nil end }
hl = { ui = { document = doc }, hold_pos = { page = 1 }, selected_text = { text = "", sboxes = { {} } },
    clear = function() cleared = true end }
Assert.is_false(Ocr.fillSelection(hl))
Assert.eq(prompts, 1)
Assert.is_true(cleared)

-- 重排文档（没有 getOCRText）：原样放行。
hl = { ui = { document = {} }, hold_pos = { page = 1 }, selected_text = { text = "", sboxes = { {} } } }
Assert.is_true(Ocr.fillSelection(hl))

return true
