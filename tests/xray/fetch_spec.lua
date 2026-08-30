--[[-- xray.fetch：mock AI.jsonExtract，校验合并落库调用。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end

local saved = { entities = {} }
local entity_rows = {}
package.preload["db.xray"] = function()
    return {
        list = function(_, _, kind)
            local out = {}
            for _, row in ipairs(entity_rows) do
                if not kind or row.kind == kind then
                    out[#out + 1] = row
                end
            end
            return out
        end,
        replace = function(_, _, entities)
            entity_rows = {}
            saved.entities = {}
            for _, entity in ipairs(entities or {}) do
                entity_rows[#entity_rows + 1] = entity
            end
            saved.entities = entity_rows
            return true
        end,
    }
end
package.preload["xray.context"] = function()
    return {
        forAnalysis = function()
            return {
                current_page = "Mina at Whitby saw Dracula",
                prior_text = "prior",
                page = 5,
            }
        end,
        currentPage = function() return 5 end,
    }
end
package.preload["ai"] = function()
    return {
        isConfigured = function() return true end,
        jsonExtract = function(_, _, cb)
            cb({
                book_type = "fiction",
                characters = {
                    { name = "Mina", aliases = { "Mina Harker" }, role = "heroine", description = "brave" },
                },
                locations = {
                    { name = "Whitby", description = "town" },
                },
                terms = {
                    { name = "Dracula", aliases = {}, description = "title" },
                },
            })
        end,
    }
end

package.loaded["xray.store"] = nil
package.loaded["xray.fetch"] = nil
package.loaded["xray.prompts"] = nil

local Fetch = require("xray.fetch")
local identity = { source_id = "moon", stable_id = "book", book = { title = "Dracula", authors = "Stoker" } }
local result, failure
Fetch.comprehensive({}, identity, { force = true }, function(value, err)
    result, failure = value, err
end)

Assert.is_nil(failure)
Assert.eq(#result.characters, 1)
Assert.eq(result.characters[1].name, "Mina")
Assert.eq(#result.locations, 1)
Assert.eq(#result.terms, 1)
Assert.eq(#saved.entities, 3)
entity_rows = {
    { kind = "character", name = "Old", aliases = {}, role = "", description = "", updated_at = 1 },
}
saved.entities = { { kind = "character", name = "Old" } }
package.loaded["xray.fetch"] = nil
Fetch = require("xray.fetch")
Fetch.comprehensive({}, identity, { force = true }, function(value, err)
    result, failure = value, err
end)
Assert.is_nil(failure)
Assert.eq(#result.characters, 2)
local names = {}
for _, row in ipairs(result.characters) do names[row.name] = true end
Assert.is_true(names.Old)
Assert.is_true(names.Mina)
Assert.eq(#saved.entities, 4)

-- 未在上下文中出现的名称应被丢弃
package.preload["ai"] = function()
    return {
        isConfigured = function() return true end,
        jsonExtract = function(_, _, cb)
            cb({
                characters = {
                    { name = "Mina", aliases = {}, role = "heroine", description = "brave" },
                    { name = "Imaginary", aliases = {}, role = "none", description = "nope" },
                },
                locations = {},
                terms = {},
            })
        end,
    }
end
entity_rows = {}
saved.entities = {}
package.loaded["xray.fetch"] = nil
Fetch = require("xray.fetch")
Fetch.comprehensive({}, identity, { force = true }, function(value, err)
    result, failure = value, err
end)
Assert.is_nil(failure)
Assert.eq(#result.characters, 1)
Assert.eq(result.characters[1].name, "Mina")
