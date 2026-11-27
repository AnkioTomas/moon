--[[--
http.mirror：留给已发布插件的兼容表。检查更新只读 RELEASE_PROXIES。

@module tests.http.mirror_spec
--]]

local Assert = require("support.assert")

local Mirror = require("http.mirror")
local Github = require("http.github")

Assert.eq(#Mirror.RELEASE_PROXIES, #Github.FALLBACK_RELEASE)
for i, prefix in ipairs(Github.FALLBACK_RELEASE) do
    Assert.eq(Mirror.RELEASE_PROXIES[i], prefix)
    local path = "/AnkioTomas/ko-paper-sprite/releases/download/v1/paper-sprite.koplugin.zip"
    local url = prefix .. path
    Assert.is_true(url:find("https://", 1, true) == 1)
    Assert.is_true(url:find(path, 1, true) ~= nil)
end

-- 旧插件 unpack 后就地洗牌，不能改到 github 的兜底表
local first = Github.FALLBACK_RELEASE[1]
Mirror.RELEASE_PROXIES[1] = "mutated"
Assert.eq(Github.FALLBACK_RELEASE[1], first)
