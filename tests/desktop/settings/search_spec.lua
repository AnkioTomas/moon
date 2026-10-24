local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.guard"] = function() return {} end
package.preload["ui.themes.widgets.row"] = function() return {} end
local Search = require("desktop.pages.setting.search")

local function hit(title, subtitle, trail)
    return { title = title, text = (title .. " " .. (subtitle or "") .. " " .. trail):lower() }
end
local hits = { hit("夜间模式", "自动切换", "屏幕"), hit("WebDAV", "上传本地书", "账号"), hit("字体", nil, "阅读") }

Assert.eq(Search.match(hits, "webdav")[1].title, "WebDAV")
Assert.len(Search.match(hits, "上传 本地"), 1)
Assert.len(Search.match(hits, "上传 屏幕"), 0)
Assert.len(Search.match(hits, "  "), 0)
Assert.eq(Search.match(hits, "阅读")[1].title, "字体")
