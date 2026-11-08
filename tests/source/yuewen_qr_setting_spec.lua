--[[--
阅文三源的设备扫码入口：各用自己的应用参数，先校验再保存；起点补双提交 CSRF。

@module tests.source.yuewen_qr_setting_spec
--]]

local Assert = require("support.assert")
local beginLogin = require("source.auth").beginLogin
local Themed = require("support.theme_stubs")
Themed.install()
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(spec) return spec end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenConnected = function(_self, fn) fn() end }
end
package.preload["source.review_setting"] = function()
    return { row = function() return function() return {} end end }
end
package.preload["source.category_setting"] = package.preload["source.review_setting"]
local configs, saved_id, authorized, reloads = {}, nil, nil, 0
package.preload["utils.settings"] = function()
    return {
        getSource = function(id) configs[id] = configs[id] or {}; return configs[id] end,
        saveSource = function(id) saved_id = id end,
    }
end
package.loaded["source.auth"] = nil
package.preload["source.auth"] = function()
    return { beginLogin = beginLogin, ok = function(id) authorized = id end, expired = function() return false end }
end
package.preload["source.registry"] = function()
    return { reload = function() reloads = reloads + 1 end }
end
package.preload["utils.random"] = function()
    return { hex = function(size) Assert.eq(size, 16); return string.rep("a", size * 2) end }
end
local options, on_cookie, started, checked, reject
package.preload["source.yuewen_qr"] = function()
    return { new = function(_self, spec, cb)
        options, on_cookie = spec, cb
        return { start = function() started = true end }
    end }
end
for _idx, id in ipairs({ "qqreader", "qidian", "xiaoxiang" }) do
    package.preload["source." .. id .. ".client"] = function()
        return {
            cookie = function() return configs[id] and configs[id].cookie end,
            loginCheckAsync = function(cookie, cb)
                checked = cookie
                cb(not reject, reject and "rejected" or nil, { id = "123" })
            end,
            userAsync = function(cookie, cb)
                checked = cookie
                cb(not reject and { id = "123" } or nil, reject and "rejected" or nil)
            end,
        }
    end
end

for _idx, source in ipairs({
    { id = "qqreader", app_id = "1450000220", area_id = "1" },
    { id = "qidian", app_id = "13", area_id = "31" },
    { id = "xiaoxiang", app_id = "57", area_id = "5" },
}) do
    local Setting = require("source." .. source.id .. ".setting")
    started, checked, saved_id, authorized = nil, nil, nil, nil
    local rows = Setting.rows()
    rows[1](400).callback()
    Assert.is_true(started, "账号行直接启动设备扫码")
    Assert.eq(options.app_id, source.app_id)
    Assert.eq(options.area_id, source.area_id)
    Assert.is_nil(saved_id, "仅获取二维码不能保存登录态")
    reject = true
    on_cookie("ywguid=guid; ywkey=bad")
    Assert.is_nil(saved_id, "各源的账号校验失败时不保存")
    Assert.is_nil(authorized)
    Assert.eq(Themed.last("toast").text, "rejected")
    Assert.is_true(Themed.last("progress_dialog").closed)
    reject = false
    on_cookie("ywguid=guid; ywkey=key")
    Assert.eq(saved_id, source.id)
    Assert.eq(authorized, source.id)
    Assert.eq(configs[source.id].cookie, checked)
    if source.id == "qidian" then
        Assert.matches(checked, "; _csrfToken=" .. string.rep("a", 32))
    else
        Assert.eq(checked, "ywguid=guid; ywkey=key")
    end
    Assert.eq(Themed.last("toast").text, "登录成功")
    started = nil
    Setting.login()
    Assert.is_true(started, "登录失效的直达入口也走设备扫码")
    if source.id ~= "qqreader" then
        local paste
        for _idx, factory in ipairs(Setting.rows()) do
            local row = factory(400)
            if row.title == "粘贴 Cookie" then paste = row; break end
        end
        Assert.not_nil(paste)
        paste.callback()
        Assert.eq(Themed.last("input").title, source.id == "qidian" and "起点登录 Cookie" or "潇湘登录 Cookie")
    end
end
Assert.eq(reloads, 3)
