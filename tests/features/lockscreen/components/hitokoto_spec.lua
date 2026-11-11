--[[--
锁屏一言：ttl==0 时 needs_network 为假；拉取走 ensureConfigured，不直接 ensure。
@module tests.features.lockscreen.components.hitokoto_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(s) return s end end
package.preload["l10n"] = function() return { apply = function() end } end

local ttl = 3600
local quotes = { { text = "缓存句", source = "S" } }
local ensured = 0
package.preload["online.hitokoto"] = function()
    return {
        configuredTtl = function() return ttl end,
        ensureConfigured = function() ensured = ensured + 1 end,
        quotes = function() return quotes end,
        stable = function()
            return quotes[1] or { text = "回退", source = "F" }
        end,
        fallback = function() return { text = "回退", source = "F" } end,
    }
end
package.preload["features.lockscreen.components.quote_panel"] = function()
    return { blocks = function(text, source)
        return { { text = text, source = source } }
    end }
end
package.preload["features.lockscreen.cycle"] = function()
    return { pending = function() return "#1" end }
end

local C = require("features.lockscreen.components.hitokoto")
Assert.eq(type(C.needs_network), "function")
ttl = 3600
Assert.is_true(C.needs_network())
ttl = 0
Assert.is_false(C.needs_network(), "不联网时锁屏可离线出图")

ensured = 0
ttl = 0
quotes = { { text = "缓存句", source = "S" } }
Assert.eq(C.cache_key(), "缓存句")
Assert.eq(ensured, 1)
local blocks = C.blocks("center", true)
Assert.eq(blocks[1].text, "缓存句")
Assert.eq(ensured, 2)

quotes = {}
Assert.eq(C.cache_key(), "回退#1")
Assert.eq(C.blocks("center", true)[1].text, "回退")

return true
