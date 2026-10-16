--[[--
静态检查：代码里经 `utils.settings` 读写的分区键，都要在 `<owner>/setting.lua` 的 defaults 或 keys 里声明。
只认两种写法：`.get("owner").key`，以及 `local v = <...>.get("owner")` 之后的 `v.key`。

@module tests.utils.settings_keys_spec
--]]

local Assert = require("support.assert")

local root = (debug.getinfo(1, "S").source:match("^@(.+)/tests/") or ".") .. "/book.koplugin"

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local declared = {}
local function declaredKeys(owner)
    if declared[owner] then return declared[owner] end
    local f = io.open(root .. "/" .. owner:gsub("%.", "/") .. "/setting.lua", "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    local keys = {}
    -- 只取第一层：先把嵌套的子表抹掉
    local defaults = (s:match("defaults%s*=%s*(%b{})") or "{}"):sub(2, -2):gsub("%b{}", "")
    for key in defaults:gmatch("([%w_]+)%s*=") do keys[key] = true end
    local list = s:match("keys%s*=%s*(%b{})") or ""
    for key in list:gmatch('"([%w_]+)"') do keys[key] = true end
    declared[owner] = keys
    return keys
end

-- passcode 的 salt / hash 等键名太泛：登记进 keys 会让旧分区里同名键被迁移进来，故意不声明
local IGNORE = { ["features.passcode"] = true }

local missing = {}
local function check(path, owner, key)
    if IGNORE[owner] then return end
    local keys = declaredKeys(owner)
    if keys and not keys[key] then missing[#missing + 1] = path:sub(#root + 2) .. ": " .. owner .. "." .. key end
end

local pipe = assert(io.popen('find "' .. root .. '" -name "*.lua"'))
for path in pipe:lines() do
    local s = read(path)
    for owner, key in s:gmatch('%.get%("([%w%._]+)"%)%.([%w_]+)') do check(path, owner, key) end
    for var, owner in s:gmatch('local ([%w_]+) = [%w_%.%(%)"]-%.get%("([%w%._]+)"%)\n') do
        for key in s:gmatch("[^%w_%.\"'/]" .. var .. "%.([%w_]+)") do check(path, owner, key) end
    end
end
pipe:close()

Assert.eq(table.concat(missing, "\n"), "")
