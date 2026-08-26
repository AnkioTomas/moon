--[[-- xray.graph：跨页人物、事件和关系去重。 --]]

local Assert = require("support.assert")
local Graph = require("xray.graph")

local page = {
    characters = { { name = "甲", role = "主角", description = "" } },
    events = { { name = "相遇", description = "甲遇见乙", participants = { "甲", "乙" } } },
    relations = { { from = "甲", to = "乙", type = "同伴", description = "同行" } },
}
local graph = Graph.merge({ page, page })
Assert.len(graph.characters, 1)
Assert.len(graph.events, 1)
Assert.len(graph.relations, 1)
local output = Graph.format(graph)
Assert.matches(output, "甲 → 乙")
Assert.matches(output, "相遇")
