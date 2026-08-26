--[[--
source.registry 离线用例

@module tests.source.registry_spec
--]]

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    local common = { active_source = "moon" }
    return {
        activeSourceId = function()
            return common.active_source
        end,
        get = function()
            return common
        end,
        save = function(s)
            common = s
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
    Assert.is_true(ids["local"])
end

do
    local src, err = Registry.create("local")
    Assert.is_true(src ~= nil, err)
    Assert.eq(src.id, "local")
    Assert.eq(src.type, "book")
    local caps = src:capabilities()
    Assert.is_true(caps.scrape)
    Assert.is_nil(caps.whole_book)
    Assert.is_true(type(src.recentBooksAsync) == "function")
    Assert.is_true(type(src.coverRequest) == "function")
    Assert.is_false(src:configured())
end

do
    local src, err = Registry.create("moon")
    Assert.is_true(src ~= nil, err)
    Assert.eq(src.id, "moon")
    Assert.eq(src.type, "book")
    local caps = src:capabilities()
    Assert.is_true(caps.insight)
    Assert.is_false(caps.scrape)
end

do
    Assert.eq(Registry.meta("wechat").type, "online")
    Assert.eq(Registry.meta("copymanga").type, "online")
end

do
    local src, err = Registry.create("nope")
    Assert.is_nil(src)
    Assert.is_true(type(err) == "string")
end

-- 启用源：默认全开；禁用/启用非活跃源；活跃源禁止禁用
do
    -- 无 enabled_sources（旧配置）：全真，listEnabled == list
    Assert.is_true(Registry.isEnabled("copymanga"))
    Assert.is_true(Registry.isEnabled("moon"))
    Assert.eq(#Registry.listEnabled(), #Registry.list())

    -- 禁用非活跃源：首次写入以全开初始化集合
    Assert.is_true(Registry.setEnabled("copymanga", false))
    Assert.is_false(Registry.isEnabled("copymanga"))
    Assert.eq(#Registry.listEnabled(), #Registry.list() - 1)

    -- 再启用回来
    Assert.is_true(Registry.setEnabled("copymanga", true))
    Assert.is_true(Registry.isEnabled("copymanga"))
    Assert.eq(#Registry.listEnabled(), #Registry.list())

    -- 活跃源（stub 固定 moon）禁止禁用；isEnabled 兜底恒 true
    local ok, err = Registry.setEnabled("moon", false)
    Assert.is_false(ok)
    Assert.not_nil(err)
    Assert.is_true(Registry.isEnabled("moon"))

    -- 未知源
    Assert.is_false(Registry.setEnabled("nope", true))
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
