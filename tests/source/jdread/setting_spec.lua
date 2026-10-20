--[[--
京东扫码登录对话框：点击即出占位框，任何方式关框都取消在飞的取码/轮询。

@module tests.source.jdread.setting_spec
--]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

package.preload["ui/widget/container/centercontainer"] = function()
    return { new = function(_, o) return { content = o[1] } end }
end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
end
package.preload["ui.themes.widgets.text"] = function()
    return { box = function(_, text, width) return { text = text, width = width } end }
end
package.preload["ui.themes"] = function()
    return { current = function() return { dialog = { bg = 0 } } end }
end
local invalidated
package.preload["ui.themes.widgets.image"] = function()
    return {
        widget = function(o) return { src = o.src } end,
        invalidate = function(path) invalidated = path end,
    }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end

local begin_cb, wait_cb, complete_cb, browser_payload
local begin_cancels, wait_cancels, begin_count = 0, 0, 0
package.preload["source.jdread.auth"] = function()
    return {
        hasSession = function() return false end,
        userLabel = function() return nil end,
        beginQrLoginAsync = function(cb)
            begin_count = begin_count + 1
            begin_cb = cb
            return { cancel = function() begin_cancels = begin_cancels + 1 end }
        end,
        waitQrLoginAsync = function(_, cb)
            wait_cb = cb
            return { cancel = function() wait_cancels = wait_cancels + 1 end }
        end,
        completeQrLoginAsync = function(_, cb)
            complete_cb = cb
            return { cancel = function() end }
        end,
        importBrowserAsync = function(payload, cb)
            cb(payload == browser_payload)
        end,
    }
end

--- 对话框正文（二维码 / 占位字）。
local function content(sheet)
    return sheet.items[1].widget(500).content
end

package.loaded["source.jdread.setting"] = nil
local Setting = require("source.jdread.setting")
local login = Setting.rows()[1]().callback

browser_payload = {}
Assert.eq(Setting.browser.domain, "e.m.jd.com")
Assert.eq(Setting.browser.scope, "cookie")
Assert.eq(Setting.browser.login, Setting.browser.check)
local browser_ok
Setting.browser.apply(browser_payload, function(ok) browser_ok = ok end)
Assert.is_true(browser_ok)

-- 点击即同步出占位框盖住入口，不等取码网络往返。
login()
local placeholder = Themed.last("sheet")
Assert.is_true(placeholder.shown)
Assert.eq(content(placeholder).text, "正在获取二维码…")
Assert.not_nil(begin_cb)

-- 取码途中点框外 / 返回键 / 取消按钮都是关窗：取消取码，回调迟到也不再弹二维码。
placeholder:close()
Assert.eq(begin_cancels, 1)
begin_cb({ qr_path = "qr.png", token = "t", jar = {} })
Assert.len(Themed.all("sheet"), 1)
Assert.is_nil(wait_cb)

-- 二维码出来后换框（旧占位框关掉，不算取消），关新框取消轮询。
login()
placeholder = Themed.last("sheet")
begin_cb({ qr_path = "qr.png", token = "t", jar = {} })
local qr = Themed.last("sheet")
Assert.is_true(placeholder.closed)
Assert.eq(begin_cancels, 1, "代码换框不算用户取消")
Assert.eq(content(qr).src, "qr.png")
-- 每次登录都复用同一路径，不作废位图缓存会显示上一张已失效的码。
Assert.eq(invalidated, "qr.png")
Assert.not_nil(wait_cb)
qr:close()
Assert.eq(wait_cancels, 1)
local sheets = #Themed.made
wait_cb(nil, "迟到的失败", "error")
Assert.eq(#Themed.made, sheets, "已取消的轮询不应再弹提示")

-- 取码失败：关掉占位框再提示。
login()
placeholder = Themed.last("sheet")
begin_cb(nil, "获取失败")
Assert.is_true(placeholder.closed)
Assert.eq(Themed.last("toast").text, "获取失败")

-- 校验成功但没拿到会话：不自动换码，留框显示原因，点「重新获取二维码」才重来。
login()
begin_cb({ qr_path = "qr-old.png", token = "t", jar = {} })
local begins = begin_count
wait_cb({ ticket = "ticket", jar = {} }, nil, "ok")
Assert.not_nil(complete_cb)
complete_cb(nil, "登录未拿到会话 Cookie")
Assert.eq(begin_count, begins, "失败后不自动换码")
local failed = Themed.last("sheet")
Assert.is_true(failed.shown)
Assert.is_false(failed.closed == true)
Assert.eq(content(failed).text, "登录未拿到会话 Cookie")
local retry = failed.items[2]
Assert.eq(retry.text, "重新获取二维码")
-- 与真实 Sheet 一致：先关框再回调。
failed:close()
retry.callback()
Assert.eq(begin_count, begins + 1)
Assert.eq(content(Themed.last("sheet")).text, "正在获取二维码…")
