local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.guard"] = function()
    return { call = function(_label, fn, ...) return fn(...) end }
end
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

-- searchable = false 的页面只索引页面入口本身，绝不调用其 sections() 展开海量动态行。
local expanded = false
local built = Search.build({
    {
        entries = {
            {
                title = "插件市场",
                subtitle = "浏览并安装插件",
                page = {
                    id = "feature:marketplace:marketplace",
                    title = "插件市场",
                    searchable = false,
                    sections = function()
                        expanded = true
                        return { { title = "浏览", rows = {} } }
                    end,
                },
            },
        },
    },
})
Assert.is_false(expanded, "searchable=false 时不得展开 sections")
Assert.len(Search.match(built, "插件市场"), 1)
