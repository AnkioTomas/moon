--[[--
配置备份 / 恢复：GET /api/backup 下载月读的分区配置，POST /api/backup 上传恢复。

范围：settings/ 下各拥有者分区（`<拥有者>/setting.lua` 的末段，见 utils.settings）。
不含：源 / 书城配置（source/<id>/、store/<id>/ 下的登录态、Cookie、令牌）、
锁屏密码分区（passcode），以及分区顶层键名像密钥的项（*_key、token、password…）。
恢复时这些键保留设备现值；备份里没有的分区不动。

格式是 Lua 表（与 settings 文件同一 dump，类型无损），恢复时在空环境、限步数下执行，
整份校验通过后才逐个分区就地改写（不换表，持有旧引用的模块不会把旧值刷回去），随后重启 KOReader。

@module koplugin.book.features.remote.backup
--]]

local Backup = {}

Backup.FORMAT = "moon-settings-backup"
Backup.VERSION = 1
Backup.BODY_LIMIT = 1024 * 1024

local EXCLUDED = { passcode = true }
local SECRET_WORDS = { "key", "apikey", "token", "secret", "password", "passwd", "cookie", "cookies", "session", "salt", "hash", "auth" }

local PLUGIN_ROOT = debug.getinfo(1, "S").source:match("^@(.*)/features/remote/backup%.lua$") or "."

---@param key any
---@return boolean
function Backup.isSecret(key)
    if type(key) ~= "string" then return false end
    key = key:lower()
    for _idx, word in ipairs(SECRET_WORDS) do
        if key == word or key:sub(-#word - 1) == "_" .. word then return true end
    end
    return false
end

local _sections

--- 可备份的分区名：插件内 setting.lua 的末段目录名，跳过源 / 书城子目录与排除名单。
--- 插件文件运行中不变（更新后会重启），扫一次即缓存。
---@return table<string, boolean>
function Backup.sections()
    if _sections then return _sections end
    local lfs = require("libs/libkoreader-lfs")
    local out = {}
    local function walk(dir, rel)
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local path, sub = dir .. "/" .. name, rel == "" and name or rel .. "/" .. name
                if lfs.attributes(path, "mode") == "directory" then
                    if not sub:match("^source/[^/]+$") and not sub:match("^store/[^/]+$") then walk(path, sub) end
                elseif name == "setting.lua" and rel ~= "" then
                    local section = rel:match("[^/]+$")
                    if not EXCLUDED[section] then out[section] = true end
                end
            end
        end
    end
    walk(PLUGIN_ROOT, "")
    _sections = out
    return out
end

--- 序列化当前配置（取 utils.settings 的内存实例，未落盘的改动也在内）。
---@return string text Lua 源文本
function Backup.build()
    local sections = {}
    for name in pairs(Backup.sections()) do
        local data, copy = require("utils.settings").getSource(name), {}
        for key, value in pairs(data) do
            if not Backup.isSecret(key) then copy[key] = value end
        end
        if next(copy) then sections[name] = copy end
    end
    return "-- 月读配置备份\nreturn " .. require("dump")({
        format = Backup.FORMAT, version = Backup.VERSION, created = os.time(), sections = sections,
    }, nil, true) .. "\n"
end

--- 值只许字符串 / 数字 / 布尔 / 表（键为字符串或数字）。
local function plain(v, depth)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return true end
    if t ~= "table" or depth > 32 then return false end
    for k, nested in pairs(v) do
        local kt = type(k)
        if (kt ~= "string" and kt ~= "number") or not plain(nested, depth + 1) then return false end
    end
    return true
end

--- 在空环境里解释执行备份文本，限 100 万条指令（防死循环）。
---@param text string
---@return table|nil doc, string|nil err
local function parse(text)
    if type(text) ~= "string" or text == "" or text:byte(1) == 27 then return nil, "invalid backup" end
    local fn = loadstring(text, "=backup")
    if not fn then return nil, "invalid backup" end
    setfenv(fn, {})
    if jit then jit.off(fn, true) end -- 编译后的循环不触发计数钩子
    debug.sethook(function() error("backup too complex") end, "", 1e6)
    local ok, doc = pcall(fn)
    debug.sethook()
    if not ok or type(doc) ~= "table" or doc.format ~= Backup.FORMAT then return nil, "invalid backup" end
    if doc.version ~= Backup.VERSION then return nil, "unsupported backup version" end
    if type(doc.sections) ~= "table" or not plain(doc.sections, 0) then return nil, "invalid backup" end
    return doc
end

--- 校验整份备份后恢复：只写可备份的分区，密钥键保留现值。
---@param text string
---@return string[]|nil restored 已恢复的分区名, string|nil err
function Backup.restore(text)
    local doc, err = parse(text)
    if not doc then return nil, err end
    local allowed, names = Backup.sections(), {}
    for name, values in pairs(doc.sections) do
        if allowed[name] and type(values) == "table" then names[#names + 1] = name end
    end
    if #names == 0 then return nil, "backup has no settings" end
    table.sort(names)
    local Settings = require("utils.settings")
    for _idx, name in ipairs(names) do
        local data = Settings.getSource(name)
        for key in pairs(data) do
            if not Backup.isSecret(key) then data[key] = nil end
        end
        for key, value in pairs(doc.sections[name]) do
            if not Backup.isSecret(key) then data[key] = value end
        end
        Settings.saveSource(name)
    end
    return names
end

--- 备份文件名 moon-settings-YYYYMMDD-HHMM.lua
---@return string
function Backup.fileName()
    return os.date("moon-settings-%Y%m%d-%H%M.lua")
end

--- 路由：GET 下载、POST 恢复（恢复成功后 handlers.settings_restored 负责提示并重启）。
---@param conn table
---@param method string
---@param headers table
function Backup.route(self, conn, method, headers)
    if method == "GET" then
        return self:_queueResponse(conn, {
            code = 200, ctype = "text/plain; charset=utf-8", body = Backup.build(),
            extra = {
                "Content-Disposition: attachment; filename*=UTF-8''" .. Backup.fileName(),
                "Cache-Control: no-store",
            },
        })
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    return self:_acceptText(conn, headers, Backup.BODY_LIMIT, function(server, c, text)
        local names, err = Backup.restore(text)
        if not names then return server:_fail(c, 400, err) end
        server:_json(c, 200, require("json").encode({ ok = true, sections = names }))
        if server.handlers.settings_restored then server.handlers.settings_restored() end
    end)
end

return Backup
