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
local stash_ok = true
local last_toast
local last_confirm
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
        stashOldRoot = function(old_root, new_root)
            forgotten[#forgotten + 1] = { old_root, new_root }
            return stash_ok
        end,
    }
end
package.preload["desktop.sync"] = function()
    return { rescan = function() rescanned = true end }
end
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_self, opts) last_toast = opts.text; return { show = function() end } end }
end
package.preload["ui.themes.widgets.confirm"] = function()
    return { new = function(_, opts)
        last_confirm = opts.text
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

-- 重选当前普通目录不弹换根提醒。
cfg.path = "/mnt/us/documents/books"
last_confirm, forgotten = nil, {}
Setting.open(nil, plugin.desktop)
item("使用此目录").callback()
Assert.is_nil(last_confirm)
Assert.len(forgotten, 0)

-- 换书库目录：进子目录确认 → 先收成待重匹配 + 强制重扫，不 reload；并提醒用当前根下的文件夹分类
cfg.path = "/mnt/us/documents"
forgotten, rescanned, reloaded, last_confirm = {}, false, false, nil
row(1).callback()
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
Assert.is_true(last_confirm:find("只是给书分类的话", 1, true) ~= nil)
Assert.is_true(last_confirm:find("按文件夹分类", 1, true) ~= nil)

-- 无桌面（书城引导）：走 reload
cfg.path = "/mnt/us/documents"
forgotten, rescanned, reloaded = {}, false, false
Setting.open(nil, nil)
item("books").callback()
item("使用此目录").callback()
Assert.len(forgotten, 1)
Assert.is_true(reloaded)
Assert.is_true(not rescanned)

-- 准备失败不保存新根、不扫描或重载，也不能执行成功回调。
cfg.path, stash_ok = "/mnt/us/documents", false
rescanned, reloaded = false, false
local saved_before, completed = saved, false
Setting.open(function() completed = true end, plugin.desktop)
item("books").callback()
item("使用此目录").callback()
Assert.eq(cfg.path, "/mnt/us/documents")
Assert.eq(saved, saved_before)
Assert.eq(last_toast, "准备书库记录失败")
Assert.is_false(rescanned)
Assert.is_false(reloaded)
Assert.is_false(completed)
