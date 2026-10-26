--[[--
远程管理网页文案目录（features/remote/l10n/web）：en 与 zh_TW 键集一致、值非空、占位符一致；
非模板键必须出现在网页源码（html/*.html|js）或远程管理 Lua 里，防止残留废弃键。

@module tests.features.remote.l10n_web_spec
--]]

local Assert = require("support.assert")
local root = require("support.config").root()

local en = require("features.remote.l10n.web.en")
local zh_tw = require("features.remote.l10n.web.zh_TW")

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
    "find %s/book.koplugin/features/remote -not -path '*/l10n/*' \\( -name '*.html' -o -name '*.js' -o -name '*.lua' \\)", root)))
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
Assert.len(stale, 0, "features/remote/l10n/web 残留网页已不用的键: " .. table.concat(stale, " | "))

-- catalog() 只给插件目录；网页目录由 /api/i18n 合并（见 server_spec）
local L10n = require("l10n")
Assert.eq((L10n.catalog("en_US")), "en")
Assert.eq((L10n.catalog("zh_HK")), "zh_TW")
local cn_name, cn = L10n.catalog("zh_CN.UTF-8")
Assert.eq(cn_name, "zh_CN")
Assert.is_nil(next(cn))
Assert.eq((L10n.catalog("de_DE")), "en")
