--[[-- xray.store：别名去重。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end
package.preload["db.xray"] = function()
    return {}
end

local Store = require("xray.store")

local merged = Store.mergeEntities({
    {
        kind = "character",
        name = "John",
        aliases = {},
        description = "boy",
    },
}, {
    {
        kind = "character",
        name = "John Doe",
        aliases = { "John" },
        role = "hero", description = "grown",
    },
    {
        kind = "location",
        name = "Whitby",
        aliases = {},
        description = "port",
    },
})

Assert.eq(#merged, 2)
local john
for index, entity in ipairs(merged) do
    if entity.kind == "character" then john = entity end
end
Assert.is_true(john ~= nil)
Assert.eq(john.name, "John")
Assert.eq(john.role, "hero")
Assert.eq(john.description, "grown")
local aliases = {}
for index, alias in ipairs(john.aliases or {}) do aliases[#aliases + 1] = alias end
Assert.is_true(
    aliases[1] == "John Doe" or aliases[2] == "John Doe",
    "alternate name should become alias"
)

-- 别名只在同一实体类型内去重；人物别名不能吞掉同名地点。
merged = Store.mergeEntities({
    { kind = "character", name = "Alice", aliases = { "Paris" } },
}, {
    { kind = "location", name = "Paris", aliases = {}, description = "city" },
})
Assert.eq(#merged, 2)
Assert.eq(merged[2].kind, "location")
Assert.eq(merged[2].name, "Paris")
