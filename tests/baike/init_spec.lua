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
package.preload["baike.client"] = function()
    return { lookupAsync = function() error("not called in this spec") end }
end

local settings = { baike_enabled = true }
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end

local native_lookup_calls = 0
local native_input_calls = 0
local native_menu_calls = 0
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
