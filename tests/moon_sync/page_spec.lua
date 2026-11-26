--[[--
月读同步设置页：连接行还在，但已经不挂在本地书源那一页。

@module tests.moon_sync.page_spec
--]]

local Assert = require("support.assert")

local moon = {
    migrated = true,
    sync_fonts = false,
    webdav_url = "https://dav.example/dav",
    webdav_username = "user",
    webdav_password = "secret",
    webdav_path = "Books",
}
local local_cfg = {}

package.preload["utils.settings"] = function()
    return {
        get = function() return moon end,
        save = function() end,
        getSource = function() return local_cfg end,
        saveSource = function() end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["gettext"] = function()
    return setmetatable({ translation = {}, current_lang = "zh_CN" }, {
        __call = function(_, text) return text end,
    })
end
package.loaded["utils.settings"] = nil
package.loaded["ui.themes.widgets.row"] = nil
package.loaded["gettext"] = nil
package.loaded["moon_sync"] = nil
package.loaded["moon_sync.page"] = nil

local Page = require("moon_sync.page")
local sections = Page.sections(nil)
local titles = {}
for _idx, section in ipairs(sections) do
    for _row_idx, build in ipairs(section.rows) do
        titles[#titles + 1] = build(100).title
    end
end
Assert.eq(table.concat(titles, ","), table.concat({
    "WebDAV 地址", "WebDAV 用户名", "WebDAV 密码", "WebDAV 目录", "测试 WebDAV 连接",
    "同步字体", "同步书籍附属数据", "立即同步",
}, ","))

local path_row = sections[1].rows[4](100)
Assert.eq(path_row.title, "WebDAV 目录")
Assert.eq(path_row.status, "Books")
moon.webdav_path = ""
Assert.eq(sections[1].rows[4](100).status, "Apps/Books", "没填目录就用静读天下的默认路径")
moon.webdav_path = "Books"

local fonts = sections[2].rows[1](100)
Assert.eq(fonts.status, "关")
fonts.callback()
Assert.eq(moon.sync_fonts, true)

moon.sync_extra = true
local extra = sections[2].rows[2](100)
Assert.eq(extra.status, "开")
extra.callback()
Assert.eq(moon.sync_extra, false)
