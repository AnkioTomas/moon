--[[--
0.8 起镜像调度在 `http.github`。已经发出去的插件（paper-sprite、games、书源等）
检查更新时仍执行 `require("http.mirror").RELEASE_PROXIES`，再随机抽几个前缀做 Release 竞速。
模块不在，这些插件连自更新都进不去，修过的新版本也下不来。

前缀拼在 `https://github.com` 之后的路径上，与 `http.github` 的 Release 兜底是同一份。

@module koplugin.book.http.mirror
--]]

local Github = require("http.github")

local Mirror = {}

-- 调用方会 unpack 后就地洗牌，给一份拷贝，别让它改到 Github.FALLBACK_RELEASE。
local proxies = {}
for i, prefix in ipairs(Github.FALLBACK_RELEASE) do
    proxies[i] = prefix
end
Mirror.RELEASE_PROXIES = proxies

return Mirror
