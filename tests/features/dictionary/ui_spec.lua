--[[-- features.dictionary.ui：管理/下载入口存在。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end

local Themed = require("support.theme_stubs")
Themed.install()
local installed_paths = {}
local catalog_items = {}
local activated
local install_dir
package.preload["features.dictionary.manager"] = function()
    return {
        list = function() return installed_paths end,
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
local followed = {}
package.preload["workers.ui.task_dialog"] = function()
    return {
        start = function(spec)
            local task, reason = require("workers.tasks").enqueue(spec)
            followed[#followed + 1] = task or reason
        end,
    }
end

package.loaded["features.dictionary.ui"] = nil
local Dictionary = require("features.dictionary.ui")
Dictionary.manage({ dictionary = { data_dir = "/tmp" } })
-- 无已安装词典时只提示，不弹列表
Assert.len(Themed.all("list"), 0)
Assert.eq(Themed.last("toast").text, "尚未安装字典")

installed_paths = { "/tmp/book-demo/demo.ifo" }
local changed = 0
Dictionary.manage({ dictionary = { data_dir = "/tmp" } }, function()
    changed = changed + 1
end)
Assert.len(Themed.all("list"), 1)
Themed.choose(Themed.last("list"), 1)
local sheet = Themed.last("sheet")
Assert.len(sheet.items, 2, "本插件装的字典可删除")
sheet.items[1].callback()
Assert.eq(activated, installed_paths[1])
Assert.eq(changed, 1)

catalog_items = {
    { id = "zh", name = "中文", size = 1, lang = "zh_CN", lang_name = "简体中文" },
    { id = "en", name = "English", size = 1, lang = "en", lang_name = "英语" },
}
Dictionary.download({ dictionary = { data_dir = "/tmp" } })
local loading = Themed.last("progress_dialog")
Assert.eq(loading.text, "正在获取字典目录…")
Assert.eq(loading.dismissable, false)
Assert.is_true(loading.closed, "目录拉完收起进度窗")
local language_list = Themed.last("list")
Assert.len(language_list.items, 2)
Assert.is_true(language_list.items[1].keep_open)
Themed.choose(language_list, 1)
Assert.is_nil(language_list.closed, "语言列表保持打开")
local lang_list = Themed.last("list")
Assert.eq(lang_list.title, "下载字典 · 简体中文")
Themed.choose(lang_list, 1)
Themed.last("confirm").ok_callback()
Assert.eq(install_dir, "/tmp")
-- 资源下载任务：前台跟随，进度按字节，完成后切换并提示。
Assert.len(followed, 1)
Assert.eq(followed[1].kind, "download")
Assert.eq(followed[1].title, "中文")
Assert.eq(followed[1].count, 1)
Assert.is_true(followed[1].done)
Assert.eq(Themed.last("toast").text, "字典已安装并切换")

-- 只有一种语言时直接进该语言的列表。
catalog_items = {
    { id = "zh", name = "中文", size = 1, lang = "zh_CN", lang_name = "简体中文" },
}
Dictionary.download({ dictionary = { data_dir = "/dict" } })
Assert.eq(Themed.last("list").title, "下载字典 · 简体中文")
Themed.choose(Themed.last("list"), 1)
Themed.last("confirm").ok_callback()
Assert.eq(install_dir, "/dict")

-- 查词弹窗切换：激活、关窗、重查当前词。
local looked, closed_window
local ui = { dictionary = { data_dir = "/tmp", onLookupWord = function(_, word) looked = word end } }
Dictionary.pick(ui, { word = "moon", current_name = "demo", close_window = function() closed_window = true end })
local pick = Themed.last("list")
Assert.is_true(pick.items[1].checked)
Assert.eq(pick.subtitle, "选择后重新查询当前词")
activated = nil
Themed.choose(pick, 1)
Assert.eq(activated, installed_paths[1])
Assert.is_true(closed_window)
Assert.eq(looked, "moon")
