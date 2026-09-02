--[[-- xray.kinds：实体类型与底部 Tab 使用同一份元数据。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local Kinds = require("xray.kinds")

Assert.eq(#Kinds, 3)
Assert.eq(Kinds[1].id, "character")
Assert.eq(Kinds[1].text, "人物")
Assert.eq(Kinds[1].icon, "person")
Assert.eq(Kinds.label("location"), "地点")
Assert.eq(Kinds.label("unknown"), "unknown")
