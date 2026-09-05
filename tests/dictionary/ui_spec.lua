--[[-- dictionary.ui：管理/下载入口存在。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end

local lists = {}
local sheets = {}
local shown = {}
package.preload["ui.components.popup"] = function()
    return {
        list = function(opts) lists[#lists + 1] = opts end,
        single = function(opts) lists[#lists + 1] = opts end,
        sheet = function(opts) sheets[#sheets + 1] = opts end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function() end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, opts) return opts end }
end
local progress_dialog
package.preload["ui/widget/progressbardialog"] = function()
    return {
        new = function(_, opts)
            progress_dialog = opts
            opts.progress = {}
            opts.show = function() opts.shown = true end
            opts.close = function() opts.closed = true end
            opts.reportProgress = function(_, value) opts.progress[#opts.progress + 1] = value end
            return opts
        end,
    }
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/data" end }
end
local installed_paths = {}
local catalog_items = {}
local activated
local install_dir
package.preload["dictionary.manager"] = function()
    return {
        installed = function() return installed_paths end,
        isInstalled = function() return false end,
        catalog = function(cb) cb(catalog_items) end,
        activate = function(_, path) activated = path end,
        remove = function() return true end,
        refresh = function() end,
        install = function(_, data_dir, cb, on_progress)
            install_dir = data_dir
            on_progress("part", 1, 1, 1, 1)
            cb(true)
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, cb) cb() end }
end
package.preload["utils.text"] = function()
    return { trim = function(s) return s end }
end

package.loaded["dictionary.ui"] = nil
local Dictionary = require("dictionary.ui")
Dictionary.manage({ dictionary = { data_dir = "/tmp" } })
-- 无已安装词典时只提示，不弹列表
Assert.eq(#lists, 0)

installed_paths = { "/tmp/book-demo/demo.ifo" }
local changed = 0
Dictionary.manage({ dictionary = { data_dir = "/tmp" } }, function()
    changed = changed + 1
end)
Assert.eq(#lists, 1)
lists[1].items[1].callback()
Assert.eq(#sheets, 1)
sheets[1].items[1].callback()
Assert.eq(activated, installed_paths[1])
Assert.eq(changed, 1)

catalog_items = {
    { id = "zh", name = "中文", size = 1, lang = "zh_CN", lang_name = "简体中文" },
    { id = "en", name = "English", size = 1, lang = "en", lang_name = "英语" },
}
Dictionary.download({ dictionary = { data_dir = "/tmp" } })
local language_list = lists[2]
Assert.len(language_list.items, 2)
Assert.is_true(language_list.items[1].keep_menu_open)
language_list.items[1].callback()
Assert.eq(lists[3].title, "下载字典 · 简体中文")
lists[3].items[1].callback()
shown[#shown].ok_callback()
Assert.eq(install_dir, "/tmp")
Assert.is_true(progress_dialog.shown)
Assert.is_true(progress_dialog.closed)
Assert.eq(progress_dialog.progress[1], 1)

-- 桌面没有 ReaderUI 时仍按 KOReader 默认目录安装。
catalog_items = {
    { id = "zh", name = "中文", size = 1, lang = "zh_CN", lang_name = "简体中文" },
}
Dictionary.download(nil)
local desktop_download = lists[#lists]
desktop_download.items[1].callback()
shown[#shown].ok_callback()
Assert.eq(install_dir, "/data/data/dict")

Assert.is_true(type(Dictionary.download) == "function")
Assert.is_true(type(Dictionary.pick) == "function")
