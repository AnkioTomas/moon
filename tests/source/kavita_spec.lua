local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local cfg = {}
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local Kavita = require("source.kavita")

local meta = Kavita.meta()
Assert.eq(meta.id, "kavita")
Assert.eq(meta.name, "Kavita")
Assert.eq(meta.type, "book")

cfg = {}
local source = Kavita.new()
local caps = source:capabilities()
Assert.is_true(caps.search)
Assert.is_true(caps.refresh)
Assert.is_false(caps.scrape)
Assert.is_false(caps.edit)
Assert.is_true(caps.insight)
Assert.is_false(caps.stats_pull)

Assert.is_false(source:configured())

cfg = { base_url = "https://host:port/kavita", api_key = "test-key" }
source = Kavita.new()
Assert.is_true(source:configured())

cfg = { base_url = "https://host:port/kavita", api_key = "" }
source = Kavita.new()
Assert.is_false(source:configured())

cfg = { base_url = "", api_key = "test-key" }
source = Kavita.new()
Assert.is_false(source:configured())

cfg = { base_url = "https://host:port/kavita", api_key = "test-key" }
source = Kavita.new()
local cover, err = source:coverRequest({ source_id = "kavita", stable_id = "42" })
Assert.is_nil(err)
Assert.eq(cover.url, "https://host:port/kavita/api/Image/series-cover?seriesId=42")
Assert.eq(cover.headers["x-api-key"], "test-key")

cfg = { base_url = "", api_key = "" }
source = Kavita.new()
local cover2, err2 = source:coverRequest({ source_id = "kavita", stable_id = "42" })
Assert.is_nil(cover2)
Assert.not_nil(err2)

cfg = { base_url = "https://host:port/kavita", api_key = "test-key" }
source = Kavita.new()
local cover3, err3 = source:coverRequest(nil)
Assert.is_nil(cover3)
Assert.not_nil(err3)
