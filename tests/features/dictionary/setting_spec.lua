---@diagnostic disable: missing-fields
--[[-- features.dictionary.setting：桌面入口必须交出挂着 ReaderDictionary 的真实宿主。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_self, text) return text end })
end
local settings = { dictionary_enabled = true }
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
local reader = { instance = nil }
local file_manager = { instance = { name = "fm" } }
package.preload["apps/reader/readerui"] = function() return reader end
package.preload["apps/filemanager/filemanager"] = function() return file_manager end
local calls = {}
package.preload["features.dictionary.ui"] = function()
    return {
        download = function(ui) calls[#calls + 1] = { "download", ui } end,
        manage = function(ui) calls[#calls + 1] = { "manage", ui } end,
    }
end

local Setting = require("features.dictionary.setting")
local entry = Setting.entries({ updateView = function() end })[1]
Assert.eq(entry.parent, "lookup")
local rows = entry.sections()[1].rows
Assert.len(rows, 3)
rows[2](100).callback()
rows[3](100).callback()
Assert.eq(calls[1][1], "download")
Assert.eq(calls[1][2], file_manager.instance, "桌面上没有阅读器：用文件管理器的词典实例刷新缓存")
Assert.eq(calls[2][2], file_manager.instance)

reader.instance = { name = "reader" }
rows[3](100).callback()
Assert.eq(calls[3][2], reader.instance, "阅读器开着时用阅读器的实例")
