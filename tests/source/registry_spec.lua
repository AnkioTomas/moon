--[[--
source.registry 离线用例

@module tests.source.registry_spec
--]]

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    local active = "moon"
    return {
        activeSourceId = function()
            return active
        end,
        get = function()
            return { active_source = active }
        end,
        save = function(s)
            active = s.active_source
        end,
        getSource = function()
            return { url = "http://x", token = "t", username = "u", password = "p" }
        end,
    }
end

-- 避免真实 HTTP 构造
package.preload["source.moon.client"] = function()
    local C = {}
    function C:new()
        return setmetatable({ configured = function() return true end }, { __index = C })
    end
    function C:configured() return true end
    return C
end
package.preload["source.moon.mapper"] = function()
    return { list = function() return { data = {}, count = 0 } end }
end
package.preload["source.wechat.auth"] = function()
    return { hasSession = function() return true end }
end
package.preload["source.wechat.client"] = function()
    local C = {}
    function C:new() return setmetatable({}, { __index = C }) end
    return C
end
package.preload["source.wechat.mapper"] = function() return {} end
package.preload["source.wechat.chapter"] = function()
    return { ensure = function() return true end }
end
package.preload["http.webdav"] = function()
    return {
        new = function()
            return {
                ping = function() return true end,
                list = function() return {} end,
                get = function() return true end,
            }
        end,
    }
end

-- 清掉可能缓存的模块
package.loaded["source.registry"] = nil
package.loaded["source.moon"] = nil
package.loaded["source.wechat"] = nil
package.loaded["source.webdav"] = nil

local Registry = require("source.registry")

do
    local list = Registry.list()
    local ids = {}
    for _, m in ipairs(list) do
        ids[m.id] = true
    end
    Assert.is_true(ids.moon)
    Assert.is_true(ids.wechat)
    Assert.is_true(ids.webdav)
end

do
    local src, err = Registry.create("moon")
    Assert.is_true(src ~= nil, err)
    Assert.eq(src.id, "moon")
    local caps = src:capabilities()
    Assert.is_true(caps.whole_book)
    Assert.is_true(caps.insight)
    Assert.is_false(caps.chapters)
end

do
    local src, err = Registry.create("nope")
    Assert.is_nil(src)
    Assert.is_true(type(err) == "string")
end

-- 清理 preload，避免污染后续用例
for _, k in ipairs({
    "utils.settings",
    "source.moon.client",
    "source.moon.mapper",
    "source.wechat.auth",
    "source.wechat.client",
    "source.wechat.mapper",
    "source.wechat.chapter",
    "http.webdav",
    "source.registry",
    "source.moon",
    "source.wechat",
    "source.webdav",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
