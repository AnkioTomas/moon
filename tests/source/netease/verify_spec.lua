--[[--
密码图形验证码：同一会话取图、刷新、取消与迟到回调。

@module tests.source.netease.verify_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local loads, cancelled, results = {}, 0, {}
local decode_fails = false
package.loaded["ui.themes"] = { px = function(n) return n end }
package.loaded["ui/widget/imagewidget"] = { new = function(_class, opts) return opts end }
package.loaded["ui/renderimage"] = {
    renderImageData = function(_self, raw, size, frames)
        Assert.eq(raw, "picture")
        Assert.eq(size, 7)
        Assert.is_false(frames)
        if not decode_fails then return { bitmap = true } end
    end,
}
local session = {
    captchaAsync = function(_self, cb) loads[#loads + 1] = cb end,
    cancel = function() cancelled = cancelled + 1 end,
}
local Verification = require("source.netease.verify")
local function done(code) results[#results + 1] = code or false end
local verification = Verification.new(session, done)
Assert.is_true(Themed.last("progress_dialog").shown)
loads[#loads]("picture")
local input = Themed.last("input")
Assert.is_true(input.header_widget.image.bitmap)
Assert.eq(input.ok_text, "登录")
Assert.is_false(input.validate(" "))
Assert.eq(Themed.last("toast").text, "请输入图形码")
input.actions[1].callback()
Assert.is_true(input.closed)
Assert.len(loads, 2)
loads[#loads]("picture")
input = Themed.last("input")
input.callback(" ab12 ")
Assert.eq(results[1], "ab12")
Assert.is_true(verification.done)
Assert.eq(cancelled, 1)

verification = Verification.new(session, done)
local before = #Themed.all("input")
Themed.last("progress_dialog").on_cancel()
loads[#loads]("picture")
Assert.len(Themed.all("input"), before)
Assert.eq(results[2], false)
Assert.eq(cancelled, 2)
verification = Verification.new(session, done)
loads[#loads](nil, "network down")
Assert.eq(Themed.last("toast").text, "network down")
Assert.is_true(verification.done)
decode_fails = true
verification = Verification.new(session, done)
loads[#loads]("picture")
Assert.eq(Themed.last("toast").text, "图形验证码加载失败")
Assert.is_true(verification.done)
