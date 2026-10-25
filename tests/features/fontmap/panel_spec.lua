--[[-- 阅读快捷面板能重开当前书籍的字体映射；设置页无阅读实例时也可收集动作。 --]]
local Assert = require("support.assert")
local requested
local supported = true
local state = { start = function(_self, value) requested = value end }
package.loaded["features.fontmap"] = {
    supported = function() return supported end,
    available = function(ui) return ui.rolling ~= nil end,
    new = function() return state end,
}
local action = require("features.fontmap.panel").actions()[1]
Assert.eq(action.scope, "reader")
Assert.is_true(action.available({ ui = nil }))
Assert.is_false(action.available({ ui = {} }))
local ui = { rolling = {} }
Assert.is_true(action.available({ ui = ui }))
action.run({ ui = ui })
Assert.eq(ui._book_fontmap, state)
Assert.is_true(requested)
supported = false
Assert.is_false(action.available({ ui = nil }), "低版本设置页不提供动作")
Assert.is_false(action.available({ ui = ui }))
supported = true
requested = nil
action.run({ ui = {} })
Assert.is_nil(requested, "不支持的文档不创建状态、不启动扫描")
