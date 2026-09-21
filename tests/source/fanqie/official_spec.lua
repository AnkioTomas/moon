--[[--
番茄正文入口：走 reading API。

@module tests.source.fanqie.official_spec
--]]

local Assert = require("support.assert")

package.loaded["source.fanqie.official"] = nil
local Official = require("source.fanqie.official")

Assert.eq(type(Official.fetchAsync), "function")
