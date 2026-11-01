--[[--
锁屏主体注册表接受第三方插件的 components()，坏条目跳过，出错的 blocks 变成空表。

@module tests.features.lockscreen.components.external_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(s) return s end end
package.preload["utils.log"] = function()
    return { error = function() end, warn = function() end, dbg = function() end }
end

for _idx, name in ipairs({
    "stats", "hitokoto", "highlight", "current", "capsule", "minimal", "receipt", "bill", "message",
}) do
    package.preload["features.lockscreen.components." .. name] = function()
        return { id = name, label = name, blocks = function() return {} end }
    end
end

local ready = true
local exts = {}
package.preload["source.registry"] = function()
    return {
        extensions = function() return exts end,
        extensionsReady = function() return ready end,
    }
end

package.loaded["features.lockscreen.components.base"] = nil
package.loaded["utils.external"] = nil
package.loaded["source.registry"] = nil

local Components = require("features.lockscreen.components.base")

exts[1] = { id = "ext.demo", features = { lockscreen = {
    components = function()
        return {
            { id = "postcard", label = "明信片", layout = "free", supports_narrow = false, supports_position = true,
                blocks = function() return { { text = "ok" } } end,
                cache_key = function() return "k" end },
            { id = "postcard", label = "重复", blocks = function() return {} end },
            { label = "缺 id", blocks = function() return {} end },
            { id = "boom", label = "会炸", blocks = function() error("boom") end },
        }
    end,
} } }

local found = Components.find("ext.demo.postcard")
Assert.eq(found.layout, "free")
Assert.eq(found.supports_narrow, false)
Assert.eq(found.cache_key(), "k")
Assert.eq(found.blocks("center-center", true)[1].text, "ok")
Assert.eq(Components.find("current").id, "current")
Assert.eq(#Components.find("ext.demo.boom").blocks(), 0)

local saw = 0
for _idx, item in ipairs(Components.options()) do
    if item.value == "ext.demo.postcard" then saw = saw + 1 end
end
Assert.eq(saw, 1, "duplicate id is skipped")
Assert.is_true(Components.find("none") ~= nil)

ready = false
exts[1] = nil
Assert.is_true(Components.resolvable("ext.demo.postcard"))
ready = true
Assert.eq(Components.resolvable("ext.demo.postcard"), false)
Assert.is_true(Components.resolvable("none"))
