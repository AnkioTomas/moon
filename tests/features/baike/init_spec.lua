---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- 百度百科注入：开关开启时替换，关闭时回退 KOReader 原生入口。 @module tests.features.baike.init_spec --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end
package.preload["logger"] = function()
    return { dbg = function() end }
end
local requests = {}
local offline = false
local online_retry
package.preload["features.baike.client"] = function()
    return {
        lookupAsync = function(word, callback)
            local job = {
                cancelled = false,
                cancel = function(self)
                    self.cancelled = true
                end,
            }
            requests[#requests + 1] = {
                word = word,
                callback = callback,
                job = job,
            }
            return job
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        willRerunWhenOnline = function(_, callback)
            if offline then
                online_retry = callback
                return true
            end
            return false
        end,
    }
end

local settings = { baike_enabled = true }
package.preload["utils.settings"] = function()
    return { get = function(name) assert(name == "features.baike"); return settings end }
end

local native_lookup_calls = 0
local native_input_calls = 0
local native_menu_calls = 0
local shown_progress = {}
local shown_results = {}
local ReaderWikipedia = {
    lookupWikipedia = function()
        native_lookup_calls = native_lookup_calls + 1
        return "native lookup"
    end,
    lookupInput = function()
        native_input_calls = native_input_calls + 1
        return "native input"
    end,
    addToMainMenu = function()
        native_menu_calls = native_menu_calls + 1
        return "native menu"
    end,
    cleanSelection = function(_, word)
        return word
    end,
    showLookupInfo = function(self, word)
        local progress = { word = word, closed = false }
        self.lookup_progress_msg = progress
        shown_progress[#shown_progress + 1] = progress
    end,
    dismissLookupInfo = function(self)
        if self.lookup_progress_msg then
            self.lookup_progress_msg.closed = true
            self.lookup_progress_msg = nil
        end
    end,
    showDict = function(self, word, results)
        self:dismissLookupInfo()
        shown_results[#shown_results + 1] = {
            word = word,
            results = results,
            is_wiki = self.is_wiki,
        }
    end,
    is_wiki = true,
}
package.preload["apps/reader/modules/readerwikipedia"] = function()
    return ReaderWikipedia
end

local DictQuickLookup = {
    _getButtonPool = function()
        return { wikipedia = { text = "Wikipedia", text_func = function() return "Wikipedia" end } }
    end,
}
package.preload["ui/widget/dictquicklookup"] = function()
    return DictQuickLookup
end

local ReaderHighlight = {
    long_press_action = { { "Translate", "translate" }, { "Wikipedia", "wikipedia" } },
}
package.preload["apps/reader/modules/readerhighlight"] = function()
    return ReaderHighlight
end

local Dispatcher = {
    getNameFromItem = function(_, item)
        return "native:" .. item
    end,
}
package.preload["dispatcher"] = function()
    return Dispatcher
end

local Baike = require("features.baike")
Assert.is_true(Baike.isEnabled())
Baike.onCreate()
Assert.eq(ReaderHighlight.long_press_action[2][1], "百度百科")
Assert.eq(ReaderHighlight.long_press_action[1][1], "Translate")
Assert.eq(Dispatcher:getNameFromItem("wikipedia_lookup"), "百度百科查询")
Assert.eq(Dispatcher:getNameFromItem("show_menu"), "native:show_menu")

-- 划词菜单 / 高亮弹窗 / 长按 / 手势的百科都走 lookupWikipedia：开四合一面板停在「百科」栏，不再弹原生词典窗。
local opened = {}
package.loaded["features.rare.lookup"] = { open = function(opts) opened[#opened + 1] = opts end }
ReaderWikipedia.ui = { highlight = { selected_text = { text = "选区" } } }
ReaderWikipedia:lookupWikipedia("词条", true, { { x = 1, y = 2, w = 3, h = 4 } })
Assert.len(opened, 1)
Assert.eq(opened[1].source, "baike")
Assert.eq(opened[1].text, "词条")
Assert.is_true(opened[1].from_highlight)
Assert.eq(opened[1].word_box.x, 1)
Assert.len(shown_results, 0, "不弹原生词典窗")
Assert.len(requests, 0, "请求交给面板")
ReaderWikipedia.ui = {}
ReaderWikipedia:lookupWikipedia("手势")
Assert.is_false(opened[2].from_highlight)
Assert.is_nil(opened[2].word_box)
ReaderWikipedia:lookupWikipedia("")
Assert.len(opened, 2, "空选区不开")

local pool = DictQuickLookup:_getButtonPool()
Assert.eq(pool.wikipedia.text, "百度百科")
Assert.is_nil(pool.wikipedia.text_func)

settings.baike_enabled = false
Assert.is_false(Baike.isEnabled())
Assert.eq(ReaderWikipedia:lookupWikipedia("词"), "native lookup")
Assert.eq(ReaderWikipedia:lookupInput(), "native input")
Assert.eq(ReaderWikipedia:addToMainMenu({}), "native menu")
Assert.eq(native_lookup_calls, 1)
Assert.eq(native_input_calls, 1)
Assert.eq(native_menu_calls, 1)
Assert.eq(DictQuickLookup:_getButtonPool().wikipedia.text, "Wikipedia")
Assert.eq(Dispatcher:getNameFromItem("wikipedia_lookup"), "native:wikipedia_lookup")

Baike.onCreate()
Assert.eq(native_lookup_calls, 1)
Assert.eq(ReaderHighlight.long_press_action[2][1], "Wikipedia")

settings.baike_enabled = true
Baike.onCreate()
Assert.eq(ReaderHighlight.long_press_action[2][1], "百度百科")
Assert.eq(Dispatcher:getNameFromItem("wikipedia_lookup"), "百度百科查询")
