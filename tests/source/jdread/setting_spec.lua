--[[--
京东扫码登录对话框：点击即出占位框，任何方式关框都取消在飞的取码/轮询。

@module tests.source.jdread.setting_spec
--]]

local Assert = require("support.assert")

local function widget()
    return { new = function(_, o) return o or {} end }
end

local shown, closed = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function(_, w) closed[#closed + 1] = w end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return {
        new = function(_, o)
            o.kind = "dialog"
            o.addWidget = function(self, child) self.child = child end
            return o
        end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) o.kind = "info"; return o end }
end
package.preload["ui/widget/imagewidget"] = widget
package.preload["ui/widget/textwidget"] = widget
package.preload["ui/widget/container/centercontainer"] = function()
    return { new = function(_, o) return { content = o[1] } end }
end
package.preload["ui/geometry"] = widget
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
end
package.preload["ui.components.bookui"] = function()
    return { face = function() return "face" end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end

local begin_cb, wait_cb
local begin_cancels, wait_cancels = 0, 0
package.preload["source.jdread.auth"] = function()
    return {
        hasSession = function() return false end,
        userLabel = function() return nil end,
        beginQrLoginAsync = function(cb)
            begin_cb = cb
            return { cancel = function() begin_cancels = begin_cancels + 1 end }
        end,
        waitQrLoginAsync = function(_, cb)
            wait_cb = cb
            return { cancel = function() wait_cancels = wait_cancels + 1 end }
        end,
    }
end

package.loaded["source.jdread.setting"] = nil
local Setting = require("source.jdread.setting")
local login = Setting.rows(nil)[1]().callback

-- 点击即同步出占位框盖住入口，不等取码网络往返。
login()
Assert.len(shown, 1)
Assert.eq(shown[1].kind, "dialog")
Assert.eq(shown[1].child.content.text, "正在获取二维码…")
Assert.not_nil(begin_cb)

-- 取码途中点框外 / 返回键：取消取码，回调迟到也不再弹二维码。
shown[1].tap_close_callback()
Assert.eq(begin_cancels, 1)
begin_cb({ qr_path = "qr.png", token = "t", jar = {} })
Assert.len(shown, 1)
Assert.is_nil(wait_cb)

-- 二维码出来后换框（旧占位框关掉），关新框取消轮询。
shown, closed = {}, {}
login()
local placeholder = shown[1]
begin_cb({ qr_path = "qr.png", token = "t", jar = {} })
Assert.len(shown, 2)
Assert.eq(closed[1], placeholder)
Assert.eq(shown[2].child.content.file, "qr.png")
Assert.not_nil(wait_cb)
shown[2].tap_close_callback()
Assert.eq(wait_cancels, 1)
wait_cb(nil, "迟到的失败", "error")
Assert.len(shown, 2, "已取消的轮询不应再弹提示")

-- 取码失败：关掉占位框再提示。
shown, closed = {}, {}
login()
placeholder = shown[1]
begin_cb(nil, "获取失败")
Assert.eq(closed[1], placeholder)
Assert.eq(shown[2].kind, "info")
Assert.eq(shown[2].text, "获取失败")
