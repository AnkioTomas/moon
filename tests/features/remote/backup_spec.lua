--[[--
features.remote.backup 离线测试：分区范围、密钥剔除、恢复校验与就地写入、路由。

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

local Backup = require("features.remote.backup")
local encoded
package.loaded["json"] = { encode = function(v) encoded = v return "{}" end }

-- 范围：拥有者分区在内；源 / 书城子目录（登录态）与锁屏密码不在
local sections = Backup.sections()
for _idx, name in ipairs({ "ai", "reader", "desktop", "home", "remote", "source", "store", "ui" }) do
    Assert.is_true(sections[name], "应可备份: " .. name)
end
for _idx, name in ipairs({ "wechat", "jdread", "fanqie", "moon", "copymanga", "zlib", "opds", "passcode", "common" }) do
    Assert.is_nil(sections[name], "不应备份: " .. name)
end

Assert.is_true(Backup.isSecret("ai_api_key"))
Assert.is_true(Backup.isSecret("token"))
Assert.is_true(Backup.isSecret("Password"))
Assert.is_false(Backup.isSecret("page_keys"))
Assert.is_false(Backup.isSecret("home_widgets"))

-- 备份：剔除密钥键，空分区不写
store.ai = { ai_endpoint = "https://x", ai_api_key = "sk-secret", ai_timeout = 120 }
store.reader = { list = { 3, 1, 2 }, [5] = "five" }
store.wechat = { cookie = "SESSION" }
local text = Backup.build()
Assert.is_nil(text:find("sk-secret", 1, true))
Assert.is_nil(text:find("SESSION", 1, true))

-- 恢复：类型无损，密钥保留现值，备份外的键被替换掉
store.ai = { ai_endpoint = "https://old", ai_api_key = "sk-now", stale = true }
store.reader = {}
saved = {}
local names = assert(Backup.restore(text))
Assert.eq(table.concat(names, ","), "ai,reader")
Assert.eq(table.concat(saved, ","), "ai,reader")
Assert.eq(store.ai.ai_endpoint, "https://x")
Assert.eq(store.ai.ai_api_key, "sk-now")
Assert.eq(store.ai.ai_timeout, 120)
Assert.is_nil(store.ai.stale)
Assert.eq(store.reader.list[3], 2)
Assert.eq(store.reader[5], "five")

-- 篡改：不在范围的分区忽略，备份里的密钥不生效
saved = {}
local forged = 'return { format = "moon-settings-backup", version = 1, sections = { '
    .. 'wechat = { cookie = "evil" }, ai = { ai_api_key = "sk-evil", ai_model = "m" } } }'
assert(Backup.restore(forged))
Assert.eq(store.wechat.cookie, "SESSION")
Assert.eq(store.ai.ai_api_key, "sk-now")
Assert.eq(store.ai.ai_model, "m")

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
    'return { format = "moon-settings-backup", version = 1, sections = { wechat = { a = 1 } } }',
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
Assert.eq(table.concat(encoded.sections, ","), "ai,reader")
Assert.is_true(restarted)
restarted = nil
server.body = "garbage"
Backup.route(server, {}, "POST", {})
Assert.eq(fail[1], 400)
Assert.is_nil(restarted)
Backup.route(server, {}, "DELETE", {})
Assert.eq(fail[1], 405)
