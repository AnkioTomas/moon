--[[--
番茄正文入口：client 直调 reading API。

@module tests.source.fanqie.official_spec
--]]

local Assert = require("support.assert")

package.loaded["source.fanqie.official"] = nil
package.loaded["source.fanqie.reading"] = nil
local Reading = require("source.fanqie.reading")

Assert.eq(type(Reading.fetchAsync), "function")
