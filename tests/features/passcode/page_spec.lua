--[[--
密码方式切换：验证旧凭证、两次确认新凭证；失败或取消保留原锁，关闭也必须验证。
@module tests.features.passcode.page_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.sections.passcode = {}
require("support.theme_stubs").install()
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }

local Passcode = require("features.passcode")
local Page = require("features.passcode.page")
local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }
local function row(index)
    return Page.rows(desktop)[index](500)
end
local function top()
    return Kit.shown[#Kit.shown]
end

Passcode.setPin("2468")
Assert.is_true(row(1).toggle)
Assert.is_false(row(2).toggle)
row(2).callback()
Assert.eq(top().name, "book_passcode_pad", "先验证当前 PIN，而不是新手势")
Assert.eq(top().on_submit("1234"), "密码错误")
Assert.eq(Passcode.mode(), "pin")
Assert.eq(top().on_submit("2468"), true)
Assert.eq(top().name, "book_passcode_pattern")
Assert.eq(top().on_submit("1596"), true)
Assert.eq(top().on_submit("1236"), "两次绘制不一致")
Assert.eq(Passcode.mode(), "pin", "二次确认失败，保留原 PIN")
top():close()
Assert.is_true((Passcode.verify("2468")))

row(2).callback()
top().on_submit("2468")
top().on_submit("1596")
top().on_submit("1596")
Assert.eq(Passcode.mode(), "pattern")
Assert.is_false(row(1).toggle)
Assert.is_true(row(2).toggle)
Assert.eq(updates, 1)

-- 修改手势仍要先画对旧手势；切回 PIN 时取消不影响旧手势。
row(3).callback()
Assert.eq(top().name, "book_passcode_pattern")
Assert.eq(top().on_submit("1236"), "密码错误")
top():close()
row(1).callback()
top().on_submit("1596")
Assert.eq(top().name, "book_passcode_pad")
top():close()
Assert.eq(Passcode.mode(), "pattern")
Assert.is_true((Passcode.verify("1596")))

row(1).callback()
top().on_submit("1596")
top().on_submit("8642")
top().on_submit("8642")
Assert.eq(Passcode.mode(), "pin")
Assert.is_true((Passcode.verify("8642")))
Assert.is_false((Passcode.verify("1596")), "切换后旧手势不再有效")

row(1).callback()
Assert.eq(top().on_submit("1234"), "密码错误")
Assert.is_true(Passcode.hasPin())
Assert.eq(top().on_submit("8642"), true)
Assert.is_false(Passcode.hasPin())
