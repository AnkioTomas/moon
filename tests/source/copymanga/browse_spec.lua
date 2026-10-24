--[[--
拷贝漫画书城浏览：榜单与题材共用一套 chip，题材节点走 /comics 且不高亮周期 / 受众。

@module tests.source.copymanga.browse_spec
--]]

local Assert = require("support.assert")

local fake_client = {}
local calls = {}

local function stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = nil
end

stub("utils.settings", function()
    return { getSource = function() return { token = "tok" } end, saveSource = function() end }
end)
stub("source.copymanga.client", function()
    return { new = function() return fake_client end, headers = function() return {} end,
        normalizeBaseUrl = function(url) return url end }
end)

local function page(name)
    return { results = { list = { { path_word = name, name = name } } } }
end
fake_client.rankAsync = function(_, period, audience, offset, cb)
    calls[#calls + 1] = "rank:" .. period .. ":" .. tostring(audience) .. ":" .. offset
    cb(page("r"))
    return { cancel = function() end }
end
fake_client.themeAsync = function(_, theme, offset, cb)
    calls[#calls + 1] = "theme:" .. theme .. ":" .. offset
    cb(page("t"))
    return { cancel = function() end }
end

package.loaded["source.copymanga"] = nil
local src = require("source.copymanga").new()

local res
src:browseAsync({ node = "theme:rexue", limit = 1 }, function(r) res = r end)
Assert.eq(calls[1], "theme:rexue:0")
Assert.eq(res.data[1].stable_id, "t")
Assert.len(res.groups, 2)
Assert.eq(res.groups[2].active, "theme:rexue")
Assert.is_nil(res.groups[1].active)

src:browseAsync({ limit = 1 }, function(r) res = r end)
Assert.eq(calls[2], "rank:day:nil:0")
Assert.eq(res.groups[1].active, "day:all")
Assert.eq(res.groups[2].active, "day:all")
