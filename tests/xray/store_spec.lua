--[[-- xray.store：别名去重与 timeline TOC 对齐。 --]]

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
Assert.eq(john.name, "John Doe")
Assert.eq(john.payload.role, "hero")
Assert.eq(john.payload.description, "grown")

local aligned = Store.alignTimeline({
    { chapter = "Chapter 2", event = "leaves" },
    { chapter = "Chapter 1", event = "arrives" },
}, {
    { title = "Chapter 1", page = 10 },
    { title = "Chapter 2", page = 20 },
})
Assert.eq(#aligned, 2)
Assert.eq(aligned[1].chapter, "Chapter 1")
Assert.eq(aligned[1].page, 10)
Assert.eq(aligned[1].sort_idx, 1)
Assert.eq(aligned[2].chapter, "Chapter 2")
Assert.eq(aligned[2].sort_idx, 2)
