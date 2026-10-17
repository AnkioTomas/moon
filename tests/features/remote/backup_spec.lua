--[[--
features.remote.backup 离线测试：全分区含密钥、恢复校验与就地写入、路由。

@module tests.features.remote.backup_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")

local store = {}
local saved = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function(name)
            store[name] = store[name] or {}
            return store[name]
        end,
        saveSource = function(name, values)
            Assert.is_nil(values, "恢复必须就地改表")
            saved[#saved + 1] = name
        end,
    }
end

-- CI 无 KOReader 的 frontend/dump.lua：打桩成等价的 Lua 字面量序列化
package.loaded["dump"] = nil
package.preload["dump"] = function()
    local function dump(value)
        local kind = type(value)
        if kind == "string" then return string.format("%q", value) end
        if kind ~= "table" then return tostring(value) end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = "[" .. dump(key) .. "]=" .. dump(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return dump
end

local Config = require("support.config")
local dir = Config.dir() .. "/backup_spec_settings"
os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
for _idx, f in ipairs({ "ai.lua", "reader.lua", "wechat.lua", "ext.kavita.lua", "note.txt" }) do
    io.open(dir .. "/" .. f, "w"):close()
end
package.loaded["utils.paths"] = { settingsDir = function() return dir end }

local Backup = require("features.remote.backup")
local encoded
package.loaded["json"] = { encode = function(v) encoded = v return "{}" end }

-- 范围：settings 目录下全部 *.lua（含源 / 扩展配置），其它文件不算
Assert.eq(table.concat(Backup.sections(), ","), "ai,ext.kavita,reader,wechat")
Assert.is_true(Backup.validName("ext.kavita"))
for _idx, bad_name in ipairs({ "", "../x", "a/b", ".hidden", "a..b" }) do
    Assert.is_false(Backup.validName(bad_name), bad_name)
end

-- 备份：密钥原样带上，空分区不写
store.ai = { ai_endpoint = "https://x", ai_api_key = "sk-secret", ai_timeout = 120 }
store.reader = { list = { 3, 1, 2 }, [5] = "five" }
store.wechat = { cookie = "SESSION" }
local text = Backup.build()
Assert.is_true(text:find("sk-secret", 1, true) ~= nil)
Assert.is_true(text:find("SESSION", 1, true) ~= nil)
Assert.is_nil(text:find("ext.kavita", 1, true))

-- 恢复：类型无损，分区整表替换（含密钥），备份外的分区不动
store.ai = { ai_endpoint = "https://old", ai_api_key = "sk-now", stale = true }
store.reader = {}
store.wechat = { cookie = "OLD" }
store.untouched = { v = 1 }
saved = {}
local names = assert(Backup.restore(text))
Assert.eq(table.concat(names, ","), "ai,reader,wechat")
Assert.eq(table.concat(saved, ","), "ai,reader,wechat")
Assert.eq(store.ai.ai_endpoint, "https://x")
Assert.eq(store.ai.ai_api_key, "sk-secret")
Assert.eq(store.ai.ai_timeout, 120)
Assert.is_nil(store.ai.stale)
Assert.eq(store.wechat.cookie, "SESSION")
Assert.eq(store.reader.list[3], 2)
Assert.eq(store.reader[5], "five")
Assert.eq(store.untouched.v, 1)

-- 篡改：分区名不是单层安全名整份拒绝
saved = {}
local forged = 'return { format = "moon-settings-backup", version = 1, sections = { ["../evil"] = { a = 1 } } }'
Assert.is_nil(Backup.restore(forged))
Assert.len(saved, 0)

-- 非法输入一律拒绝且不写
saved = {}
local bad = {
    "",
    "not lua (",
    "\27LuaJ",
    "return 1",
    'return { format = "other", version = 1, sections = {} }',
    'return { format = "moon-settings-backup", version = 2, sections = { ai = {} } }',
    'return { format = "moon-settings-backup", version = 1, sections = { ai = { f = function() end } } }',
    'return { format = "moon-settings-backup", version = 1, sections = { ai = { [true] = 1 } } }',
    'return os.exit()',
    'while true do end',
    'local function f() while true do end end f()',
    'return { format = "moon-settings-backup", version = 1, sections = { ["a/b"] = { a = 1 } } }',
}
for _idx, input in ipairs(bad) do
    local ok, err = Backup.restore(input)
    Assert.is_nil(ok, "应拒绝: " .. input)
    Assert.is_true(type(err) == "string")
end
Assert.len(saved, 0)

-- 路由：GET 附件下载；POST 收齐后恢复并通知设备；其它方法 405
local resp, fail, restarted
local server = {
    handlers = { settings_restored = function() restarted = true end },
    _queueResponse = function(_self, _conn, r) resp = r end,
    _fail = function(_self, _conn, code, msg) fail = { code, msg } end,
    _json = function(_self, _conn, code, body) resp = { code = code, body = body } end,
    _acceptText = function(self, conn, _headers, limit, finish)
        Assert.eq(limit, Backup.BODY_LIMIT)
        finish(self, conn, self.body)
    end,
}
Backup.route(server, {}, "GET", {})
Assert.eq(resp.code, 200)
Assert.is_true(resp.extra[1]:find("moon%-settings%-%d+%-%d+%.lua") ~= nil)
Assert.is_true(resp.body:find("moon-settings-backup", 1, true) ~= nil)
server.body = text
Backup.route(server, {}, "POST", {})
Assert.eq(resp.code, 200)
Assert.eq(table.concat(encoded.sections, ","), "ai,reader,wechat")
Assert.is_true(restarted)
restarted = nil
server.body = "garbage"
Backup.route(server, {}, "POST", {})
Assert.eq(fail[1], 400)
Assert.is_nil(restarted)
Backup.route(server, {}, "DELETE", {})
Assert.eq(fail[1], 405)

package.preload["dump"] = nil
package.loaded["dump"] = nil
