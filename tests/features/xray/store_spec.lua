--[[-- features.xray.store：别名去重。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end
package.preload["features.xray.db"] = function()
    return {}
end

local Store = require("features.xray.store")

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

-- 别名撞到另一个人的别名：不合并成一个人，别名也只归先到的那个。
merged = Store.mergeEntities({
    { kind = "character", name = "王大", aliases = { "老王" }, description = "兄" },
}, {
    { kind = "character", name = "王二", aliases = { "老王" }, description = "弟" },
})
Assert.eq(#merged, 2)
Assert.eq(#merged[2].aliases, 0, "")
Assert.eq(merged[1].aliases[1], "老王")

-- 新描述明显更短：保留旧描述；够长才覆盖。
merged = Store.mergeEntities({
    { kind = "character", name = "Mina", aliases = {}, description = "a brave young woman of Whitby" },
}, {
    { kind = "character", name = "Mina", aliases = {}, description = "brave" },
})
Assert.eq(merged[1].description, "a brave young woman of Whitby")
merged = Store.mergeEntities(merged, {
    { kind = "character", name = "Mina", aliases = {}, description = "a brave young woman of Whitby, wife of Jonathan" },
})
Assert.eq(merged[1].description, "a brave young woman of Whitby, wife of Jonathan")
