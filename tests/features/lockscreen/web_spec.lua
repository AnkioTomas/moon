--[[--
lockscreen 远程管理页：web.routes 登记（含 l10n）与网页文案目录（en / zh_TW 键集、占位符、
以及每个非模板键都还能在页面源码里找到，防止残留废弃键）。

@module tests.features.lockscreen.web_spec
--]]

local Assert = require("support.assert")
local root = require("support.config").root()

-- 只验登记表：锁屏的重活（合成、事件钩子）与本 spec 无关。
package.preload["features.lockscreen.compose"] = function() return {} end
package.preload["features.lockscreen.cycle"] = function() return { lock_cycles = 0 } end
package.preload["features.lockscreen.settings"] = function() return {} end
package.preload["utils.perf"] = function() return {} end

require("features.lockscreen")

local item
for _idx, it in ipairs(require("utils.extension").list("web.routes")) do
    if it.name == "lockscreen" then item = it end
end
Assert.not_nil(item)
Assert.eq(table.concat(item.assets, ","), "lockscreen.html,lockscreen.js,lockscreen.css")
Assert.matches(item.dir, "features/lockscreen/web$")
Assert.eq(item.page.href, "/lockscreen.html")
Assert.eq(item.l10n, "features.lockscreen.l10n.web")

local en = require("features.lockscreen.l10n.web.en")
local zh_tw = require("features.lockscreen.l10n.web.zh_TW")

local function placeholders(s)
    local out = {}
    for n in s:gmatch("%%(%d)") do out[#out + 1] = n end
    table.sort(out)
    return table.concat(out, ",")
end

for k, v in pairs(en) do
    Assert.is_true(type(v) == "string" and v ~= "", "en 空值: " .. k)
    Assert.is_true(type(zh_tw[k]) == "string" and zh_tw[k] ~= "", "zh_TW 缺键: " .. k)
    Assert.eq(placeholders(v), placeholders(k), "en 占位符不一致: " .. k)
    Assert.eq(placeholders(zh_tw[k]), placeholders(k), "zh_TW 占位符不一致: " .. k)
end
for k in pairs(zh_tw) do
    Assert.is_true(en[k] ~= nil, "en 缺键: " .. k)
end

local pipe = assert(io.popen(string.format(
    "find %s/book.koplugin/features/lockscreen -not -path '*/l10n/*' \\( -name '*.html' -o -name '*.js' -o -name '*.lua' \\)", root)))
local chunks = {}
for path in pipe:lines() do
    local fh = assert(io.open(path, "rb"))
    chunks[#chunks + 1] = fh:read("*a")
    fh:close()
end
pipe:close()
local src = table.concat(chunks, "\n")
local stale = {}
for k in pairs(en) do
    if not k:find("%%%d") and not k:find("\n") and not src:find((k:gsub("…$", "")), 1, true) then
        stale[#stale + 1] = k
    end
end
table.sort(stale)
Assert.len(stale, 0, "features/lockscreen/l10n/web 残留网页已不用的键: " .. table.concat(stale, " | "))
