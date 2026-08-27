--[[-- xray.store：别名去重。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end
package.preload["utils.db.xray"] = function()
    return {}
end

local Store = require("xray.store")

local merged = Store.mergeEntities({
    {
        kind = "character",
        name = "John",
        aliases = {},
        payload = { description = "boy" },
    },
}, {
    {
        kind = "character",
        name = "John Doe",
        aliases = { "John" },
        payload = { role = "hero", description = "grown" },
    },
    {
        kind = "location",
        name = "Whitby",
        aliases = {},
        payload = { description = "port" },
    },
})

Assert.eq(#merged, 2)
local john
for _, e in ipairs(merged) do
    if e.kind == "character" then john = e end
end
Assert.is_true(john ~= nil)
Assert.eq(john.name, "John")
Assert.eq(john.payload.role, "hero")
Assert.eq(john.payload.description, "grown")
local aliases = {}
for _, alias in ipairs(john.aliases or {}) do aliases[#aliases + 1] = alias end
Assert.is_true(
    aliases[1] == "John Doe" or aliases[2] == "John Doe",
    "alternate name should become alias"
)
