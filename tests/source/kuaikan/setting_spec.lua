--[[--
快看账号设置、浏览器域隔离和可取消 Cookie 校验。

@module tests.source.kuaikan.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["json"] = JSON
local cfg, requests, reloads, expired, connected = {}, {}, 0, false, true
package.loaded["utils.settings"] = { getSource = function() return cfg end, saveSource = function() end }
package.loaded["source.auth"] = { ok = function() expired = false end, expired = function() return expired end }
package.loaded["source.registry"] = { reload = function() reloads = reloads + 1 end }
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["ui.themes.widgets.row"] = { widget = function(opts) return opts end }
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        local r = { url = url, opts = opts, cb = cb }
        requests[#requests + 1] = r
        return { cancel = function() r.cancelled = true end }
    end,
    header = function() end, headerAll = function() return {} end,
}
local Setting = require("source.kuaikan.setting")
local answer = JSON.encode({ code = 200, data = { user_info = { authenticate = 1, user_id = 7 } } })
local ok, reason
Assert.eq(Setting.browser.check, "https://www.kuaikanmanhua.com/v2/pweb/user_info/get")
Assert.eq(Setting.browser.check_json.path, "data.user_info.authenticate")
Setting.browser.apply({ cookies = {
    { domain = ".kuaikanmanhua.com", path = "/", name = "sid", value = "parent" },
    { domain = "www.kuaikanmanhua.com", path = "/", name = "uid", value = "web" },
    { domain = "other.kuaikanmanhua.com", name = "sid", value = "other" },
    { domain = "kuaikanmanhua.com.evil.test", name = "sid", value = "evil" },
    { domain = "www.kuaikanmanhua.com", path = "/unrelated", name = "sid", value = "wrong-path" },
} }, function(value, err) ok, reason = value, err end)
Assert.eq(requests[#requests].opts.headers.Cookie, "sid=parent; uid=web")
requests[#requests].cb(answer)
Assert.is_true(ok)
Assert.eq(reloads, 1)
Assert.is_true(Setting.browser.isAuthorized())
expired = true
Assert.is_false(Setting.browser.isAuthorized())
expired = false

local rows = Setting.rows()
Assert.eq(rows[1](400).title, "快看漫画账号")
Assert.eq(rows[1](400).status, "已登录")
Assert.eq(#rows, 7)
local refreshes = 0
local review_rows = Setting.rows({ desktop = { updateView = function() refreshes = refreshes + 1 end } })
Assert.eq(review_rows[6](400).title, "章节评论")
Assert.is_false(review_rows[6](400).status_on)
review_rows[6](400).callback()
Assert.is_true(review_rows[6](400).status_on)
Assert.eq(refreshes, 1)
Assert.eq(rows[4](400).title, "密码登录")
Assert.eq(rows[5](400).title, "短信登录")
rows[3](400).callback()
Assert.eq(Themed.last("input").title, "快看登录 Cookie")
Themed.last("input").callback("sid=cancelled")
local r = requests[#requests]
Themed.last("progress_dialog").on_cancel()
Assert.is_true(r.cancelled)
r.cb(answer)
Assert.eq(reloads, 1)
Assert.eq(cfg.cookie, "sid=parent; uid=web")

connected = false
local count = #requests
rows[3](400).callback()
Themed.last("input").callback("sid=offline")
Assert.eq(#requests, count)
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
local opened
package.loaded["utils.extension"] = {
    call = function(name, path, title)
        opened = { name = name, path = path, title = title }
        return { close = function() end }
    end,
}
Assert.eq(rows[2](400).title, "浏览器登录")
rows[2](400).callback()
Assert.eq(opened.name, "web.open_page")
Assert.eq(opened.path, "/cookie.html")
package.loaded["utils.extension"] = nil

Assert.is_true(require("source.kuaikan.client").hasAccount())
for _index, row in ipairs(rows) do Assert.is_true(row(400).title ~= "快看云端同步") end
