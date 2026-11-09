--[[--
features.system_text.test：测试输入框把「是否真的收到文字」交给后端判定。

不弹真 UI，只检查对话框参数与回调映射：有文字 -> 通过，空 / 取消 -> 未通过。

@module tests.features.system_text.test_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end

local shown
package.preload["ui.themes.widgets.input"] = function()
    return {
        new = function(_, opts)
            shown = opts
            return { show = function() opts._shown = true end }
        end,
    }
end

local Test = require("features.system_text.test")

local results = {}
local function run()
    shown = nil
    Test.run(function(ok) results[#results + 1] = ok end)
    Assert.not_nil(shown, "打开测试输入框")
    return shown
end

local opts = run()
Assert.eq(opts.title, "测试系统输入法")
Assert.eq(opts.fields[1].label, "测试文本")
Assert.is_true(#opts.fields[1].hint > 0)
Assert.is_true(opts._shown)

opts.callback("你好")
Assert.eq(results[1], true, "确认且有文字 -> 通过")

opts = run()
opts.callback("")
Assert.eq(results[2], false, "确认但没有文字 -> 未通过")

opts = run()
opts.cancel_callback()
Assert.eq(results[3], false, "取消 -> 未通过")

opts = run()
opts.callback("abc")
opts.callback("")
Assert.eq(#results, 4, "一次测试只记录一次结果")
Assert.eq(results[4], true)
