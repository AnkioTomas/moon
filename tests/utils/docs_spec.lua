--[[--
官网手册 URL 拼装与打开。
@module tests.utils.docs_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(text) return text end end

local opened, can_open, qr
package.preload["device"] = function()
    return {
        canOpenLink = function() return can_open end,
        openLink = function(_, url) opened = url end,
    }
end
package.preload["ui.themes.widgets.qr"] = function()
    return {
        new = function(_, opts)
            qr = opts
            return { show = function() end }
        end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts) return opts end,
    }
end

local Docs = require("utils.docs")

Assert.eq(Docs.url(nil), "https://moon.ankio.net/manual")
Assert.eq(Docs.url(""), "https://moon.ankio.net/manual")
Assert.eq(Docs.url("/manual/device"), "https://moon.ankio.net/manual/device")
Assert.eq(Docs.url("manual/device"), "https://moon.ankio.net/manual/device")
Assert.eq(Docs.url("https://example.com/x"), "https://example.com/x")
Assert.eq(Docs.group("reader"), "/manual/reader")
Assert.is_nil(Docs.group("nope"))
Assert.eq(Docs.source("wechat"), "/manual/library/sources/novels/wechat")
Assert.eq(Docs.source("local"), "/manual/library/sources/local-host/local")
Assert.is_nil(Docs.source("thirdparty"))
Assert.eq(Docs.store("zlib"), "/manual/desktop/pages/zlib")

can_open = true
Docs.open("/manual", "使用指南")
Assert.eq(opened, "https://moon.ankio.net/manual")
Assert.is_nil(qr)

can_open = false
opened = nil
qr = nil
Docs.open("/manual/device/my-device", "使用指南")
Assert.is_nil(opened)
Assert.eq(qr.title, "使用指南")
Assert.eq(qr.text, "https://moon.ankio.net/manual/device/my-device")

local row = Docs.row("/manual/system")(400)
Assert.eq(row.title, "查看指南")
Assert.eq(row.kind, "nav")
opened = nil
can_open = true
row.callback()
Assert.eq(opened, "https://moon.ankio.net/manual/system")
