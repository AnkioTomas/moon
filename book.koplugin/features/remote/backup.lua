--[[--
配置备份 / 恢复：GET /api/backup 下载月读的全部配置，POST /api/backup 上传恢复。

范围：settings/ 目录下全部分区文件（各模块设置、源 / 书城 / 第三方扩展配置），
**包含登录态、Cookie、令牌、API Key、WebDAV 密码、锁屏密码哈希等密钥**——备份文件等同账号凭据，由用户自己保管。
恢复时备份里出现的分区整表替换（备份里没有的键被清掉），备份里没有的分区不动。

格式是 Lua 表（与 settings 文件同一 dump，类型无损），恢复时在空环境、限步数下执行，
整份校验通过后才逐个分区就地改写（不换表，持有旧引用的模块不会把旧值刷回去），随后重启 KOReader。

dump 是 KOReader 自带模块，离线 / CI 测试没有 KOReader 时要打桩。

@module koplugin.book.features.remote.backup
--]]

local Backup = {}

Backup.FORMAT = "moon-settings-backup"
Backup.VERSION = 1
Backup.BODY_LIMIT = 8 * 1024 * 1024

--- 分区名就是 settings/<名>.lua 的文件名；恢复时据此拼路径，必须是单层安全名（扩展 id 含点，如 ext.kavita）。
---@param name any
---@return boolean
function Backup.validName(name)
    return type(name) == "string" and name:match("^[%w_%-][%w_%.%-]*$") ~= nil and not name:find("..", 1, true)
end

--- 设备上现有的分区名：settings 目录下的 *.lua。
---@return string[]
function Backup.sections()
    local lfs = require("libs/libkoreader-lfs")
    local dir, out = require("utils.paths").settingsDir(), {}
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    for file in lfs.dir(dir) do
        local name = file:match("^(.+)%.lua$")
        if name and Backup.validName(name) then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

--- 序列化当前配置（取 utils.settings 的内存实例，未落盘的改动也在内）。
---@return string text Lua 源文本
function Backup.build()
    local sections = {}
    for _idx, name in ipairs(Backup.sections()) do
        local data = require("utils.settings").getSource(name)
        if next(data) then sections[name] = data end
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

--- 校验整份备份后恢复：每个分区整表替换。
---@param text string
---@return string[]|nil restored 已恢复的分区名, string|nil err
function Backup.restore(text)
    local doc, err = parse(text)
    if not doc then return nil, err end
    local names = {}
    for name, values in pairs(doc.sections) do
        if not (Backup.validName(name) and type(values) == "table") then return nil, "invalid backup" end
        names[#names + 1] = name
    end
    if #names == 0 then return nil, "backup has no settings" end
    table.sort(names)
    local Settings = require("utils.settings")
    for _idx, name in ipairs(names) do
        local data = Settings.getSource(name)
        for key in pairs(data) do data[key] = nil end
        for key, value in pairs(doc.sections[name]) do data[key] = value end
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
