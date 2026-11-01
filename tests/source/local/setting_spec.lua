--[[--
本地书源设置开关：切换只改配置并重画当前叠层。
按文件夹分类不能走 Registry.reload，否则换源广播会把设置叠层关掉。

@module tests.source.local.setting_spec
--]]

local Assert = require("support.assert")

local cfg = {}
local saved = 0
local reloaded = false
local cleared = false
local rescanned = false
local painted = 0

package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function() saved = saved + 1 end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["source.registry"] = function()
    return { reload = function() reloaded = true end, invalidate = function() end }
end
package.preload["book.books_db"] = function()
    return { clearCategories = function(id) cleared = id end }
end
package.preload["desktop.sync"] = function()
    return { rescan = function() rescanned = true end }
end

package.loaded["source.local.setting"] = nil
local Setting = require("source.local.setting")

local plugin = { desktop = { settings_overlay = { updateView = function() painted = painted + 1 end } } }

local function row(index)
    return Setting.rows(plugin)[index](100)
end

local folder = row(2)
Assert.eq(folder.title, "按文件夹分类")
Assert.eq(folder.status, "开")
folder.callback()
Assert.eq(cfg.folder_category, false)
Assert.eq(saved, 1)
Assert.eq(cleared, "local")
Assert.is_true(rescanned)
Assert.eq(painted, 1)
Assert.is_true(not reloaded)
Assert.eq(row(2).status, "关")

rescanned = false
cleared = false
row(2).callback()
Assert.eq(cfg.folder_category, true)
Assert.eq(row(2).status, "开")
Assert.eq(cleared, false)
Assert.is_true(rescanned)
Assert.eq(painted, 2)
Assert.is_true(not reloaded)

local upload = row(3)
Assert.eq(upload.title, "上传本地书到 WebDAV")
Assert.eq(upload.status, "开")
upload.callback()
Assert.eq(cfg.webdav_upload_local, false)
Assert.eq(row(3).status, "关")
Assert.eq(painted, 3)
Assert.is_true(not reloaded)
