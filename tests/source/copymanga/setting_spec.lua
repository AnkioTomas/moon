--[[--
站点选择保留已有配置，自定义非法地址不保存；登录离线立即反馈。

@module tests.source.copymanga.setting_spec
--]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()
local cfg = { base_url = "https://api.example", token = "keep" }
local saves, reloads = 0, 0
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saves = saves + 1 end,
}
package.loaded["source.registry"] = { reload = function() reloads = reloads + 1 end }
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }
local Setting = require("source.copymanga.setting")
local rows = Setting.rows()
rows[1](500).callback()
local sheet = Themed.last("sheet")
Assert.eq(sheet.items[1].text, "https://www.mangacopy.com")
Assert.eq(sheet.items[2].text, "https://www.copy4000.com")
Assert.eq(sheet.items[3].text, "https://api.manga2026.xyz")
Themed.choose(sheet, 2)
Assert.eq(cfg.base_url, "https://www.copy4000.com")
Assert.eq(cfg.token, "keep")
Assert.eq(saves, 1)
Assert.eq(reloads, 1)

rows[1](500).callback()
Assert.eq(Themed.last("sheet").items[2].variant, "primary")
Themed.choose(Themed.last("sheet"), 4)
Themed.last("input").callback("https://site.example/path")
Assert.eq(cfg.base_url, "https://www.copy4000.com")
Assert.eq(saves, 1)
Assert.eq(Themed.last("toast").text, "站点地址无效")
Themed.last("input").callback(" https://api.example/ ")
Assert.eq(cfg.base_url, "https://api.example")
Assert.eq(cfg.token, "keep")

rows[1](500).callback()
Themed.choose(Themed.last("sheet"), 3)
Assert.eq(cfg.base_url, "https://api.manga2026.xyz")
Assert.eq(cfg.token, "keep")

local network = require("ui/network/manager")
network.isConnected = function() return false end
rows[2](500).callback()
Themed.last("input").callback("user", "pass")
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
Assert.is_nil(Themed.last("progress_dialog"))
