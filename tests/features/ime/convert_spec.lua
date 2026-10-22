--[[-- features.ime.convert：只转标签之间的汉字，标签与属性不动。 --]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["features.translate.bilingual"] = function() return {} end
package.preload["reader.session.derived_note"] = function() return {} end
package.preload["json"] = function() return require("support.json_stub") end
package.preload["features.ime.script"] = function()
    return { convertTexts = function(texts, target)
        local out = {}
        for i, t in ipairs(texts) do out[i] = target == "traditional" and t:gsub("发", "發") or t:gsub("發", "发") end
        return out
    end }
end

local Convert = require("features.ime.convert")
Assert.eq(Convert.markup('<p class="发">头发 abc</p><br/><i>x</i>', "traditional"), '<p class="发">头發 abc</p><br/><i>x</i>')
Assert.eq(Convert.markup("<p>no cjk</p>", "traditional"), "<p>no cjk</p>")
Assert.eq(Convert.markup("<p>头發</p><p>發</p>", "simplified"), "<p>头发</p><p>发</p>")
