--[[--
远程管理「下载日志」：把插件日志（$DATA/.moon/book.log 及轮转件）与 KOReader crash.log
（含 crash.log.old 等轮转件）打成一个 zip，附 info.txt（插件/KOReader 版本、设备、语言、时间）。

只收日志文件本身，不碰 settings / cookie 等凭证；日志内容逐行脱敏（token、密钥、
口令、Cookie、Authorization、sk- 密钥）。单文件只取末尾 PER_FILE 字节，总量封顶 TOTAL。

纯函数为主（redact / collect / build 依赖注入），便于离线测试。

@module koplugin.book.features.remote.logs
--]]

local M = {}

M.PER_FILE = 4 * 1024 * 1024
M.TOTAL = 16 * 1024 * 1024

--- 大小写无关的 Lua 模式片段："token" → "[Tt][Oo][Kk][Ee][Nn]"
---@param word string
---@return string
local function ci(word)
    return (word:gsub("%a", function(c) return "[" .. c:upper() .. c:lower() .. "]" end))
end

local SECRET_KEYS = {
    "access_token", "refresh_token", "token", "api_key", "apikey", "api-key", "secret",
    "password", "passwd", "cookie", "session", "access_key", "authorization",
}
local VALUE = "[^%s&\"',;}]+"
local MASK = "***"

--- 日志脱敏：key=value / "key": "value" / ?key= / Bearer xxx / sk-xxx 统一替换为 ***
---@param s string
---@return string
function M.redact(s)
    s = s:gsub("(" .. ci("bearer") .. "%s+)[%w%-%._~%+/=]+", "%1" .. MASK)
    s = s:gsub("(" .. ci("basic") .. "%s+)[%w%+/=]+", "%1" .. MASK)
    s = s:gsub("sk%-[%w%-_]+", "sk-" .. MASK)
    s = s:gsub("([?&]t=)[^&%s\"']+", "%1" .. MASK)
    for _idx, key in ipairs(SECRET_KEYS) do
        local k = ci(key):gsub("%-", "%%-")
        -- "key": "value" / key = value / key: value / ?key=value
        -- %f 只从词首起配：不加的话每个字符都起一次 [%w_]*，长 base64 段是 O(n²)，Kindle 上能卡几十分钟
        s = s:gsub("(%f[%w_][%w_]*" .. k .. "[%w_]*[\"']?%s*[:=]%s*[\"']?)(" .. VALUE .. ")", function(prefix, v)
            if v == MASK then return prefix .. v end
            return prefix .. MASK
        end)
    end
    return s
end

--- 待打包日志：dirs 内文件名命中 patterns 的普通文件（不跟随软链）。
---@param lfs table libkoreader-lfs
---@param spec { dir: string, prefix: string, patterns: string[] }[]
---@return { name: string, path: string, size: number, mtime: number }[] files
---@return string[] missing 不存在/打不开的目录（写进 info.txt 的 skipped）
function M.collect(lfs, spec)
    local out, seen, missing = {}, {}, {}
    for _idx, s in ipairs(spec) do
        local ok, iter, state = pcall(lfs.dir, s.dir)
        if not ok or not iter then
            missing[#missing + 1] = s.dir
        end
        if ok and iter then
            local names = {}
            for name in iter, state do names[#names + 1] = name end
            table.sort(names)
            for _j, name in ipairs(names) do
                local path = s.dir .. "/" .. name
                local attr = lfs.symlinkattributes(path)
                if attr and attr.mode == "file" and not seen[path] then
                    for _k, pat in ipairs(s.patterns) do
                        if name:match(pat) then
                            seen[path] = true
                            out[#out + 1] = {
                                name = s.prefix .. name, path = path,
                                size = attr.size or 0, mtime = attr.modification or 0,
                            }
                            break
                        end
                    end
                end
            end
        end
    end
    return out, missing
end

--- settings.reader.lua 只导出键名（不含任何值），疑似凭证的键名也只列名字。
---@param data table|nil
---@return string
function M.settingsKeys(data)
    local keys = {}
    for k in pairs(type(data) == "table" and data or {}) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    return "settings.reader.lua keys (values omitted):\n" .. table.concat(keys, "\n") .. "\n"
end

--- info.txt 文本
---@param info table<string, any>
---@param files table[]
---@param notes string[]
---@return string
function M.infoText(info, files, notes)
    local lines = {
        "Moon (book.koplugin) logs",
        "plugin_version: " .. tostring(info.plugin_version or "?"),
        "koreader_version: " .. tostring(info.koreader_version or "?"),
        "device: " .. tostring(info.device or "?"),
        "language: " .. tostring(info.language or "?"),
        "generated: " .. tostring(info.generated or os.date("%Y-%m-%d %H:%M:%S %z")),
        "",
        "files:",
    }
    for _idx, f in ipairs(files) do
        lines[#lines + 1] = string.format("  %s  %d bytes  %s", f.name, f.size or 0,
            os.date("%Y-%m-%d %H:%M:%S", f.mtime or 0))
    end
    if #files == 0 then lines[#lines + 1] = "  (none)" end
    for _idx, n in ipairs(notes or {}) do lines[#lines + 1] = n end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Secrets (tokens, keys, passwords, cookies) are redacted as ***; settings files are not included."
    return table.concat(lines, "\n") .. "\n"
end

--- 读文件末尾 limit 字节（截断时丢掉首个不完整行）
---@param path string
---@param limit number
---@return string|nil text
---@return boolean truncated
---@return number read 实际读取字节（计入总量上限）
local function readTail(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil, false, 0 end
    local size = f:seek("end") or 0
    local truncated = size > limit
    f:seek("set", truncated and (size - limit) or 0)
    local s = f:read(limit) or ""
    f:close()
    local read = #s
    if truncated then s = s:gsub("^[^\n]*\n", "", 1) end
    return s, truncated, read
end

--- 生成 zip（内容全部经内存写入，脱敏后才落包）。
---@param output string 输出路径
---@param files table[] collect 的结果
---@param info table
---@param Writer table ffi/archiver Writer 类
---@param extras { name: string, text: string }[]|nil 内存条目（logcat、键名清单等），同样脱敏、计入上限
---@param notes string[]|nil 预置说明（如 skipped 目录）
---@return string|nil output
---@return string|nil err
function M.build(output, files, info, Writer, extras, notes)
    local writer = Writer:new()
    if not writer:open(output, "zip") then
        return nil, writer.err or "cannot create archive"
    end
    if writer.setZipCompression then writer:setZipCompression("deflate") end
    local budget, included = M.TOTAL, {}
    notes = notes or {}
    local now = os.time()
    for _idx, f in ipairs(files) do
        if budget <= 0 then
            notes[#notes + 1] = "skipped (size cap): " .. f.name
        else
            local text, truncated, read = readTail(f.path, math.min(M.PER_FILE, budget))
            if text then
                text = M.redact(text)
                budget = budget - read
                if truncated then notes[#notes + 1] = "truncated to last part: " .. f.name end
                if not writer:addFileFromMemory(f.name, text, f.mtime or now) then
                    local err = writer.err
                    writer:close()
                    os.remove(output)
                    return nil, err or "archive write failed"
                end
                included[#included + 1] = f
            end
        end
    end
    for _idx, e in ipairs(extras or {}) do
        local text = e.text or ""
        if budget <= 0 then
            notes[#notes + 1] = "skipped (size cap): " .. e.name
        elseif text == "" then
            notes[#notes + 1] = "skipped (empty): " .. e.name
        else
            local limit = math.min(M.PER_FILE, budget)
            if #text > limit then
                text = text:sub(-limit):gsub("^[^\n]*\n", "", 1)
                notes[#notes + 1] = "truncated to last part: " .. e.name
            end
            budget = budget - #text
            writer:addFileFromMemory(e.name, M.redact(text), now)
            included[#included + 1] = { name = e.name, size = #text, mtime = now }
        end
    end
    writer:addFileFromMemory("info.txt", M.infoText(info, included, notes), now)
    writer:close()
    M.fixPerms(output)
    return output
end

--- KOReader 的 Writer:addFileFromMemory 把权限写成十进制 0644（= 八进制 1204，即 --w----r-T），
--- macOS / Linux 解压后日志不可读。就地把中央目录里每个条目的外部属性改成 0100644。
---@param path string zip 路径
---@return boolean
function M.fixPerms(path)
    local f = io.open(path, "r+b")
    if not f then return false end
    local size = f:seek("end")
    local tail_len = math.min(size, 22 + 65535)
    f:seek("set", size - tail_len)
    local tail = f:read(tail_len) or ""
    local eocd
    for i = #tail - 21, 1, -1 do
        if tail:sub(i, i + 3) == "PK\5\6" then eocd = i break end
    end
    if not eocd then f:close() return false end
    local function u16(str, i) local a, b = str:byte(i, i + 1) return a + b * 256 end
    local function u32(str, i) return u16(str, i) + u16(str, i + 2) * 65536 end
    local count, cd_off = u16(tail, eocd + 10), u32(tail, eocd + 16)
    local attr = string.char(0, 0, 0xA4, 0x81) -- 0100644 << 16，小端
    local pos = cd_off
    for _idx = 1, count do
        f:seek("set", pos)
        local head = f:read(46)
        if not head or #head < 46 or head:sub(1, 4) ~= "PK\1\2" then break end
        f:seek("set", pos + 38)
        f:write(attr)
        pos = pos + 46 + u16(head, 29) + u16(head, 31) + u16(head, 33)
    end
    f:close()
    return true
end

--- 下载文件名：moon-logs-YYYYMMDD-HHMM.zip
---@param t number|nil
---@return string
function M.fileName(t)
    return os.date("moon-logs-%Y%m%d-%H%M.zip", t or os.time()) --[[@as string]]
end

return M
