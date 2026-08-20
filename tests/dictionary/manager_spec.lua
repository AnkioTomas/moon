--[[-- dictionary.manager：资源清单校验。 --]]

local Assert = require("support.assert")

package.preload["json"] = function() return {} end
package.preload["http.request"] = function() return {} end
package.preload["utils.paths"] = function() return {} end
package.preload["utils.task"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function() return {} end

local Manager = require("dictionary.manager")
local hash = string.rep("a", 64)
local item = {
    id = "xhzd", name = "新华字典", size = 5, sha256 = hash,
    parts = { { file = "xhzd.part.001", size = 5, sha256 = hash } },
}
local items = assert(Manager.validateManifest({ dictionaries = { item } }))
Assert.len(items, 1)
Assert.eq(items[1].id, "xhzd")

local bad_id = { id = "../bad", name = "bad", size = 5, sha256 = hash, parts = item.parts }
Assert.is_nil(Manager.validateManifest({ dictionaries = { bad_id } }))
local bad_part = {
    id = "xhzd", name = "bad", size = 5, sha256 = hash,
    parts = { { file = "../x", size = 5, sha256 = hash } },
}
Assert.is_nil(Manager.validateManifest({ dictionaries = { bad_part } }))
local bad_sum = {
    id = "xhzd", name = "bad", size = 6, sha256 = hash,
    parts = { { file = "xhzd.part.001", size = 5, sha256 = hash } },
}
Assert.is_nil(Manager.validateManifest({ dictionaries = { bad_sum } }))

local available_ifos = { "stale" }
local init_calls = 0
local dictionary = {
    init = function()
        local _ = available_ifos
        init_calls = init_calls + 1
    end,
}
Manager.refresh(dictionary)
Assert.is_false(available_ifos)
Assert.eq(init_calls, 1)
