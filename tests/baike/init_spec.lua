--[[-- 百度百科注入：开关开启时替换，关闭时回退 KOReader 原生入口。 @module tests.baike.init_spec --]]

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
package.preload["baike.client"] = function()
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
    return { get = function() return settings end }
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

local Baike = require("baike.init")
Assert.is_true(Baike.isEnabled())
Baike.install()

ReaderWikipedia:lookupWikipedia("第一次")
Assert.eq(requests[1].word, "第一次")
Assert.is_false(shown_progress[1].closed)

ReaderWikipedia:lookupWikipedia("第二次")
Assert.is_true(requests[1].job.cancelled)
Assert.is_true(shown_progress[1].closed)
Assert.is_false(shown_progress[2].closed)
requests[1].callback({ title = "过期", definition = "不应显示" })
Assert.len(shown_results, 0)
requests[2].callback({ title = "第二次", definition = "有效" })
Assert.len(shown_results, 1)
Assert.eq(shown_results[1].results[1].word, "第二次")
Assert.is_false(shown_results[1].is_wiki)
Assert.is_true(ReaderWikipedia.is_wiki)
Assert.is_true(shown_progress[2].closed)

ReaderWikipedia:lookupWikipedia("关闭前")
ReaderWikipedia:onCloseDocument()
Assert.is_true(requests[3].job.cancelled)
Assert.is_true(shown_progress[3].closed)
requests[3].callback({ title = "过期", definition = "不应显示" })
Assert.len(shown_results, 1)

offline = true
ReaderWikipedia:lookupWikipedia("离线查询")
Assert.not_nil(online_retry)
Assert.len(requests, 3)
ReaderWikipedia:onCloseDocument()
offline = false
online_retry()
Assert.len(requests, 3)

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

Baike.install()
Assert.eq(native_lookup_calls, 1)
