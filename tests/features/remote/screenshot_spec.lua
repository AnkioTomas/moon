--[[-- features.remote.screenshot：截图确认框注入远程分享二维码。 --]]

local Assert = require("support.assert")

local dialogs = {}
local ButtonDialog = {}
function ButtonDialog:new(opts)
    opts.addWidget = function(self, widget)
        self._added_widgets = { widget }
    end
    dialogs[#dialogs + 1] = opts
    return opts
end

package.preload["ui/widget/buttondialog"] = function() return ButtonDialog end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function()
    return function(text)
        if text == "Screenshot saved to:" then return "截图已保存至：" end
        return text
    end
end

local Screenshot = require("features.remote.screenshot")
Screenshot.onCreate()

local saved = ButtonDialog:new{
    -- Screenshoter 用 BD.filepath 包住路径；真实 KOReader 标题含不可见 bidi isolate。
    title = "截图已保存至：\n\n\226\129\166/tmp/screenshot.png\226\129\169\n",
    buttons = { { { text = "查看" } } },
}
Assert.len(saved.buttons, 2)
Assert.eq(saved.buttons[2][1].text, "通过远程管理分享")

local shown, closed = {}, {}
local connected = false
package.preload["features.remote"] = function()
    return { shareUrl = function(path)
        Assert.eq(path, "/tmp/screenshot.png")
        return "http://192.0.2.1:8080/download?path=x"
    end }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget) closed[#closed + 1] = widget end,
    }
end
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) shown[#shown + 1] = o end

-- 离线不启动远程服务，也不能关掉截图确认框。
saved.buttons[2][1].callback()
Assert.eq(#shown, 1)
Assert.eq(shown[1].text, "网络不可用，请先连接 Wi-Fi")
Assert.len(closed, 0)

connected = true
saved.buttons[2][1].callback()
Assert.eq(closed[1], saved, "二维码打开前必须关闭截图确认框")
local qr = Themed.last("qr")
Assert.eq(qr.title, "通过远程管理分享")
Assert.eq(qr.text, "http://192.0.2.1:8080/download?path=x")
Assert.eq(shown[2], qr)

return true
