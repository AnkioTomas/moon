--[[--
翻译弹窗：主题组件布局、译文分页、划词操作行。

@module tests.features.translate.popup_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
require("support.theme_stubs").install()

local clipboard = true
require("device").hasClipboard = function() return clipboard end
package.preload["features.translate.edge"] = function() return {} end
package.preload["features.translate.languages"] = function()
    return { displayName = function(_, code) return code or "自动" end }
end

local Popup = require("features.translate.popup")

local popup = Popup.TranslatePopup:new{
    translator = {},
    text = "原文",
    source_lang = "zh",
    target_lang = "ko",
    translated = "译文",
}
Assert.eq(popup.text_box.height, math.floor(Kit.SCREEN_H * 0.26))
Assert.eq(popup.text_box.text, "译文")
Assert.eq(popup.pages, 1)

local texts = {}
for _, b in ipairs(Kit.buttons(popup[1])) do texts[#texts + 1] = b.text or b.icon end
Assert.contains(texts, "源语言：zh ▼")
Assert.contains(texts, "目标语言：ko ▼")
Assert.contains(texts, "复制主要翻译")
for _, text in ipairs(texts) do Assert.is_true(text ~= "保存主要翻译到笔记") end

local full = Popup.TranslatePopup:new{
    translator = {},
    text = "整页原文",
    source_lang = "zh",
    target_lang = "ko",
    translated = "整页译文",
    full_page = true,
    from_highlight = true,
}
Assert.eq(full.text_box.height, math.floor(Kit.SCREEN_H * 0.62))

-- 长译文分页：翻页后 TextBoxWidget 按页数滚动，改译文回到第一页
full.translated = string.rep("长译文", 1000)
full:refreshView()
Assert.is_true(full.pages > 1)
full:turn(1)
Assert.eq(full.page, 2)
Assert.eq(full.text_box.scrolled, 1)
full:turn(-5)
Assert.eq(full.page, 1)
full:turn(1)
full.translated = "短"
full:refreshView()
Assert.eq(full.page, 1)
Assert.eq(full.pages, 1)

texts = {}
for _, b in ipairs(Kit.buttons(full[1])) do texts[#texts + 1] = b.text end
Assert.contains(texts, "保存主要翻译到笔记")
Assert.contains(texts, "复制全部内容")

-- 请求：翻译中显示状态、复制不动作；失败显示原因；成功显示译文、检测语言保留。
local Edge = require("features.translate.edge")
local pending
Edge.translateAsync = function(_text, _to, _from, cb)
    pending = cb
    return { cancel = function() end }
end
local copied
require("device").input = { setClipboardText = function(text) copied = text end }
full:requestTranslate()
Assert.is_nil(full.translated)
Assert.eq(full.text_box.text, "正在翻译…")
local copy_main
for _, b in ipairs(Kit.buttons(full[1])) do
    if b.text == "复制主要翻译" then copy_main = b end
end
copy_main.callback()
Assert.is_nil(copied, "没有译文时不复制")
pending(nil, nil, "timeout")
Assert.eq(full.text_box.text, "翻译失败：timeout")
Assert.is_nil(full.translated)
full:requestTranslate()
pending("你好", "en")
Assert.eq(full.text_box.text, "你好")
Assert.eq(full.detected_lang, "en")
Assert.is_nil(full.status)
full:requestTranslate()
pending("再见", nil)
Assert.eq(full.detected_lang, "en", "未检测到语言时保留上次")
copy_main.callback()
Assert.eq(copied, "再见")

-- 无剪贴板、非划词：没有操作行
clipboard = false
local bare = Popup.TranslatePopup:new{ translator = {}, text = "a", translated = "b" }
for _, b in ipairs(Kit.buttons(bare[1])) do
    Assert.is_true(b.text ~= "复制主要翻译")
end

return true
