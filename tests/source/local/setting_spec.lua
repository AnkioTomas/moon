--[[--
本地书源设置开关：切换只改配置并重画当前叠层。
按文件夹分类 / 换书库目录不能走 Registry.reload，否则换源广播会把设置叠层关掉。

@module tests.source.local.setting_spec
--]]

local Assert = require("support.assert")

local cfg = { path = "/mnt/us/documents" }
local saved = 0
local reloaded = false
local cleared = false
local rescanned = false
local painted = 0
local forgotten = {}
local list

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
package.preload["book.store"] = function()
    return {
        forgetOldRoot = function(old_root, new_root)
            forgotten[#forgotten + 1] = { old_root, new_root }
            return true
        end,
    }
end
package.preload["desktop.sync"] = function()
    return { rescan = function() rescanned = true end }
end
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function() return { show = function() end } end }
end
package.preload["ui.themes.widgets.confirm"] = function()
    return { new = function(_, opts)
        return { show = function() if opts.ok_callback then opts.ok_callback() end end }
    end }
end
package.preload["ui.themes.widgets.list"] = function()
    return {
        new = function(_, opts)
            list = {
                subtitle = opts.subtitle,
                page = 1,
                items = opts.items,
                show = function() end,
                close = function() end,
                setItems = function(self, items) self.items = items end,
            }
            return list
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    local children = {
        ["/mnt/us/documents"] = { "books" },
        ["/mnt/us/documents/books"] = {},
        ["/mnt/us"] = { "documents" },
        ["/"] = { "mnt" },
        ["/mnt"] = { "us" },
    }
    return {
        attributes = function(path, mode)
            if mode == "mode" then
                return children[path] and "directory" or "directory"
            end
            return { mode = "directory" }
        end,
        dir = function(path)
            local names = children[path] or {}
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
    }
end
package.preload["utils.log"] = function()
    return { warn = function() end, dbg = function() end }
end

package.loaded["source.local.setting"] = nil
local Setting = require("source.local.setting")

local plugin = { desktop = { settings_overlay = { updateView = function() painted = painted + 1 end } } }

local function row(index)
    return Setting.rows(plugin)[index](100)
end

local function item(text)
    for _idx, entry in ipairs(list.items) do
        if entry.text == text then return entry end
    end
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

-- 换书库目录：进子目录确认 → 整本撕旧根书 + 强制重扫，不 reload
cfg.path = "/mnt/us/documents"
forgotten, rescanned, reloaded = {}, false, false
Setting.open(function() painted = painted + 1 end, plugin.desktop)
Assert.not_nil(list)
item("books").callback()
Assert.eq(list.subtitle, "/mnt/us/documents/books")
item("使用此目录").callback()
Assert.eq(cfg.path, "/mnt/us/documents/books")
Assert.len(forgotten, 1)
Assert.eq(forgotten[1][1], "/mnt/us/documents")
Assert.eq(forgotten[1][2], "/mnt/us/documents/books")
Assert.is_true(rescanned)
Assert.is_true(not reloaded)
Assert.eq(painted, 4)

-- 无桌面（书城引导）：走 reload
cfg.path = "/mnt/us/documents"
forgotten, rescanned, reloaded = {}, false, false
Setting.open(nil, nil)
item("books").callback()
item("使用此目录").callback()
Assert.len(forgotten, 1)
Assert.is_true(reloaded)
Assert.is_true(not rescanned)
