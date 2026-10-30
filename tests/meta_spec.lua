-- 每个 feature / 内置源都要有 _meta.lua：名称、说明、能力清单（启用页展示用）。
local Assert = ...

local ROOT = "book.koplugin"

local function dirs(sub)
    local out = {}
    local pipe = assert(io.popen("ls -d " .. ROOT .. "/" .. sub .. "/*/"))
    for line in pipe:lines() do out[#out + 1] = line:match("([^/]+)/$") end
    pipe:close()
    return out
end

local function check(label, meta)
    Assert.eq(type(meta.name), "string", label .. " 缺 name")
    Assert.eq(type(meta.description), "string", label .. " 缺 description")
    Assert.is_true(type(meta.abilities) == "table" and #meta.abilities > 0, label .. " 缺 abilities")
    for _idx, cap in ipairs(meta.abilities) do Assert.eq(type(cap), "string", label .. " 能力项必须是字符串") end
end

for _idx, name in ipairs(dirs("features")) do
    check("features/" .. name, require("features." .. name .. "._meta"))
end

local Registry = require("source.registry")
local checked = 0
for _idx, name in ipairs(dirs("source")) do
    local f = io.open(ROOT .. "/source/" .. name .. "/_meta.lua")
    if f then
        f:close()
        local meta = require("source." .. name .. "._meta")
        check("source/" .. name, meta)
        Assert.eq(meta.id, name, "source/" .. name .. " 的 id 必须等于目录名")
        checked = checked + 1
    end
end
for _idx, meta in ipairs(Registry.list()) do
    Assert.is_true(type(meta.description) == "string", "内置源 " .. meta.id .. " 的 meta() 要带 _meta 的说明")
end
Assert.is_true(checked >= 17, "内置源 _meta 数量")
