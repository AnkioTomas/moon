--[[-- ai.content：message / delta 正文提取。 --]]

local Assert = require("support.assert")
local Content = require("ai.content")

Assert.eq(Content.fromMessage({ content = "hello" }), "hello")
Assert.eq(Content.fromMessage({ content = "out", reasoning_content = "think" }), "out")
Assert.is_nil(Content.fromMessage({ content = "", reasoning_content = "think" }))
Assert.is_nil(Content.fromMessage({ reasoning_details = { { text = "via details" } } }))

Assert.eq(Content.fromDelta({ content = "a" }), "a")
Assert.is_nil(Content.fromDelta({ reasoning_content = "b" }))
