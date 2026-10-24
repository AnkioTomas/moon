--[[--
首次使用引导：标记为真只弹一次文档询问，弹之前先清标记；老用户（标记为假）不弹。
@module tests.desktop.welcome_spec
--]]
local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

local opened
package.loaded["device"] = { canOpenLink = function() return true end, openLink = function(_, url) opened = url end }
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

dlg.ok_callback()
Assert.matches(opened, "^https://")

Themed.made = {}
Welcome.promptDocs()
Assert.is_nil(Themed.last("confirm"))
