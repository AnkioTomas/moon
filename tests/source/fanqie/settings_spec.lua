--[[--
番茄 settings：登录判定必须以 sessionid 为准。

@module tests.source.fanqie.settings_spec
--]]

local Assert = require("support.assert")

local cfg = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function(_, value) cfg = value end,
    }
end

package.loaded["source.fanqie.settings"] = nil
local Settings = require("source.fanqie.settings")

cfg = { cookies = { novel_web_id = "1", s_v_web_id = "2" } }
Assert.is_true(not Settings:new():is_cookie_configured())

cfg = { cookies = { sessionid = "" } }
Assert.is_true(not Settings:new():is_cookie_configured())

cfg = { cookies = { sessionid = "abc", novel_web_id = "1" } }
Assert.is_true(Settings:new():is_cookie_configured())
