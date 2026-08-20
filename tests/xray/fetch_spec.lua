--[[-- xray.fetch：mock AI.jsonExtract，校验合并落库调用。 --]]

local Assert = require("support.assert")
local Json = require("support.json_stub")

package.preload["json"] = function()
    return { decode = Json.decode, encode = Json.encode }
end

local saved = { entities = {}, timeline = {} }
local entity_rows = {}
package.preload["utils.db.xray"] = function()
    return {
        listEntities = function(_, _, kind)
            local out = {}
            for _, row in ipairs(entity_rows) do
                if not kind or row.kind == kind then
                    out[#out + 1] = row
                end
            end
            return out
        end,
        listTimeline = function()
            return saved.timeline_rows or {}
        end,
        getMeta = function() return nil end,
        upsertEntity = function(_, _, kind, name, aliases_json, payload_json)
            saved.entities[#saved.entities + 1] = { kind = kind, name = name }
            entity_rows[#entity_rows + 1] = {
                kind = kind,
                name = name,
                aliases_json = aliases_json or "[]",
                payload_json = payload_json or "{}",
                updated_at = 1,
            }
            return true
        end,
        upsertTimeline = function(_, _, chapter, event, page, sort_idx)
            saved.timeline[#saved.timeline + 1] = chapter
            saved.timeline_rows = saved.timeline_rows or {}
            saved.timeline_rows[#saved.timeline_rows + 1] = {
                chapter = chapter,
                event = event,
                page = page or 0,
                sort_idx = sort_idx or 0,
                updated_at = 1,
            }
            return true
        end,
        upsertMeta = function(_, _, page, book_type)
            saved.meta = { page = page, book_type = book_type }
            return true
        end,
    }
end
package.preload["utils.db.queue"] = function()
    return { run = function(worker, opts) worker(); opts.on_done() end }
end
package.preload["xray.context"] = function()
    return {
        forAnalysis = function()
            return {
                book_text = "text",
                chapter_samples = "## Ch1 (p.1)\nhello",
                page = 5,
                toc = { { title = "Ch1", page = 1 } },
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
                timeline = {
                    { chapter = "Ch1", event = "arrives" },
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
Assert.eq(result.timeline[1].chapter, "Ch1")
Assert.eq(saved.meta.page, 5)
Assert.eq(saved.meta.book_type, "fiction")
Assert.eq(#saved.entities, 2)
Assert.eq(#saved.timeline, 1)
