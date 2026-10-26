--[[--
首次使用引导：标记为真只弹一次文档询问，弹之前先清标记；老用户（标记为假）不弹。
「查看文档」与「加入交流群」同一套打开方式：能开链接直接开，开不了出二维码。
@module tests.desktop.welcome_spec
--]]
local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

local opened, can_open = nil, true
package.loaded["device"] = {
    canOpenLink = function() return can_open end,
    openLink = function(_, url) opened = url end,
}
local saved = {}
local desktop = { docs_prompt_pending = true }
package.loaded["utils.settings"] = {
    get = function() return desktop end,
    save = function(name) saved[#saved + 1] = name end,
}

local Welcome = require("desktop.welcome")

Welcome.promptDocs()
local dlg = Themed.last("confirm")
Assert.is_true(dlg.shown)
Assert.eq(desktop.docs_prompt_pending, false)
Assert.eq(saved[1], "desktop")
Assert.eq(dlg.extra_text, "加入交流群")

dlg.ok_callback()
Assert.matches(opened, "^https://")
Assert.eq(opened, "https://moon.ankio.net")

opened = nil
dlg.extra_callback()
Assert.eq(opened, "https://qm.qq.com/q/yLPC4fxb1K")
Assert.is_nil(Themed.last("qr"), "能开链接时不出二维码")

-- 开不了链接：文档与加群都出二维码，内容就是各自的链接。
can_open = false
opened = nil
desktop.docs_prompt_pending = true
Welcome.promptDocs()
dlg = Themed.last("confirm")
dlg.ok_callback()
local qr = Themed.last("qr")
Assert.eq(qr.text, "https://moon.ankio.net")
Assert.eq(qr.caption, "https://moon.ankio.net")
dlg.extra_callback()
qr = Themed.last("qr")
Assert.eq(qr.title, "加入交流群")
Assert.eq(qr.text, "https://qm.qq.com/q/yLPC4fxb1K")
Assert.eq(qr.caption, "https://qm.qq.com/q/yLPC4fxb1K")
Assert.is_nil(opened)

Themed.made = {}
Welcome.promptDocs()
Assert.is_nil(Themed.last("confirm"))
