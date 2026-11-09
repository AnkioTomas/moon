--[[--
系统输入法测试框：打开一个真实输入框，让用户打一段字确认 SDL 文本输入通路。

有文字 → 通过；空文本 / 取消 → 未通过。结果由 features.system_text 写入
`features.system_ime.test_result`，只展示、不影响输入方式。

@module koplugin.book.features.system_text.test
--]]

local _ = require("gettext")

local Test = {}

local function finishOnce(on_done)
    local done = false
    return function(text)
        if done then return end
        done = true
        on_done(type(text) == "string" and text ~= "")
    end
end

--- 打开测试输入框；关闭 / 取消时也必须回调一次。
---@param on_done fun(ok: boolean)
function Test.run(on_done)
    local finish = finishOnce(on_done)
    local ok, Input = pcall(require, "ui.themes.widgets.input")
    if not ok or type(Input) ~= "table" then
        finish(nil)
        return
    end
    Input:new{
        title = _("测试系统输入法"),
        fields = {
            {
                label = _("测试文本"),
                hint = _("在这里输入一段文字，然后点「确定」"),
            },
        },
        ok_text = _("确定"),
        cancel_text = _("取消"),
        callback = function(text) finish(text) end,
        cancel_callback = function() finish(nil) end,
    }:show()
end

return Test
