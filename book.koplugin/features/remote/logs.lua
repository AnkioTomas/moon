--[[--
远程管理「下载日志」：把插件日志（$DATA/.moon/book.log 及轮转件）与 KOReader crash.log
（含 crash.log.old 等轮转件）打成一个 zip，附 info.txt（插件/KOReader 版本、设备、语言、时间）
与诊断快照（启用插件、脱敏后的全局/月读设置、源登录态、书库规模、各源采样 sdr）。

日志与设置值逐项脱敏（token、密钥、口令、Cookie、Authorization、sk- 密钥、路径托名）。
单文件只取末尾 PER_FILE 字节，总量封顶 TOTAL。源凭证文件只记「已配置/未配置」，不进包。

纯函数为主（redact / collect / build / dump 依赖注入），便于离线测试；
现场采集走 gatherExtras（全部 pcall，失败只记 notes）。

@module koplugin.book.features.remote.logs
--]]

local M = {}

M.PER_FILE = 4 * 1024 * 1024
M.TOTAL = 16 * 1024 * 1024
M.SAMPLE_PER_SOURCE = 3
M.CHAPTERS_PER_BOOK = 2
M.RECENT_HISTORY = 5
M.SDR_MAX = 64 * 1024

--- 大小写无关的 Lua 模式片段："token" → "[Tt][Oo][Kk][Ee][Nn]"
---@param word string
---@return string
local function ci(word)
    return (word:gsub("%a", function(c) return "[" .. c:upper() .. c:lower() .. "]" end))
end

local SECRET_KEYS = {
    "access_token", "refresh_token", "token", "api_key", "apikey", "api-key", "secret",
    "password", "passwd", "cookie", "session", "access_key", "authorization",
    "pin", "salt", "credential", "openid", "userid", "user_id", "vid",
    "username", "nickname", "email", "phone", "mobile", "display_name", "avatar",
}
local VALUE = "[^%s&\"',;}]+"
local MASK = "***"

--- 键名是否像凭证 / 账号标识（值一律 ***，不进包）。
--- 只认整词或 `_` 分段（access_token 命中 token；provider 不命中 vid）。
---@param key any
---@return boolean
function M.isSecretKey(key)
    local lk = tostring(key):lower():gsub("%-", "_")
    for _idx, s in ipairs(SECRET_KEYS) do
        local needle = s:gsub("%-", "_")
        local i = 1
        while true do
            local a, b = lk:find(needle, i, true)
            if not a then break end
            local before_ok = a == 1 or lk:sub(a - 1, a - 1) == "_"
            local after_ok = b == #lk or lk:sub(b + 1, b + 1) == "_"
            if before_ok and after_ok then return true end
            i = a + 1
        end
    end
    return false
end

--- 把绝对路径换成 $MOON / $DATA / $HOME（最长前缀优先）。roots 已按长度降序。
---@param s string
---@param roots { root: string, token: string }[]|nil
---@return string
function M.scrubPaths(s, roots)
    if type(s) ~= "string" or s == "" or not roots then return s end
    for _idx, r in ipairs(roots) do
        if r.root and r.root ~= "" and r.token then
            local plain = r.root:gsub("(%W)", "%%%1")
            s = s:gsub(plain, r.token)
        end
    end
    return s
end

--- 收集常见根路径，按长度降序，供 scrubPaths 使用。
---@return { root: string, token: string }[]
function M.pathRoots()
    local DataStorage = require("datastorage")
    local data = DataStorage:getFullDataDir()
    local roots = {
        { root = require("utils.paths").root(), token = "$MOON" },
        { root = data, token = "$DATA" },
    }
    if DataStorage.getDataDir then
        local d = DataStorage:getDataDir()
        if d and d ~= "" and d ~= data then
            roots[#roots + 1] = { root = d, token = "$DATADIR" }
        end
    end
    local home = os.getenv("HOME")
    if home and home ~= "" then
        roots[#roots + 1] = { root = home, token = "$HOME" }
    end
    table.sort(roots, function(a, b) return #a.root > #b.root end)
    return roots
end

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

--- 递归导出表为 dotted key = value；密钥键值变 ***，字符串路径托名。
---@param data table|nil
---@param roots { root: string, token: string }[]|nil
---@return string
function M.dumpTable(data, roots)
    local lines = {}
    local function walk(t, prefix)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _idx, k in ipairs(keys) do
            local path = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
            local v = t[k]
            if M.isSecretKey(k) then
                lines[#lines + 1] = path .. " = " .. MASK
            elseif type(v) == "table" then
                -- 空表也留一行，方便看「有这个键」
                local empty = true
                for _key in pairs(v) do empty = false break end
                if empty then
                    lines[#lines + 1] = path .. " = {}"
                else
                    walk(v, path)
                end
            elseif type(v) == "string" then
                lines[#lines + 1] = path .. " = " .. string.format("%q", M.scrubPaths(v, roots))
            elseif type(v) == "boolean" or type(v) == "number" then
                lines[#lines + 1] = path .. " = " .. tostring(v)
            else
                lines[#lines + 1] = path .. " = <" .. type(v) .. ">"
            end
        end
    end
    if type(data) ~= "table" then
        return "(empty)\n"
    end
    walk(data, "")
    if #lines == 0 then return "(empty)\n" end
    return table.concat(lines, "\n") .. "\n"
end

--- 启用 / 禁用插件名单。
---@param enabled { name: string }[]|string[]|nil
---@param disabled { name: string }[]|string[]|nil
---@return string
function M.pluginsText(enabled, disabled)
    local function names(list)
        local out = {}
        for _idx, p in ipairs(list or {}) do
            out[#out + 1] = type(p) == "table" and tostring(p.name or p.path or "?") or tostring(p)
        end
        table.sort(out)
        return out
    end
    local lines = { "enabled plugins:" }
    local en = names(enabled)
    if #en == 0 then lines[#lines + 1] = "  (none)" else
        for _idx, n in ipairs(en) do lines[#lines + 1] = "  " .. n end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "disabled plugins:"
    local dis = names(disabled)
    if #dis == 0 then lines[#lines + 1] = "  (none)" else
        for _idx, n in ipairs(dis) do lines[#lines + 1] = "  " .. n end
    end
    return table.concat(lines, "\n") .. "\n"
end

--- 源登录态：只写 id / enabled / configured，不要账号名与凭证。
---@param rows { id: string, enabled: boolean, configured: boolean, name: string|nil }[]|nil
---@return string
function M.accountsText(rows)
    local lines = {
        "source accounts (login status only; no credentials / display names):",
        "",
    }
    if not rows or #rows == 0 then
        lines[#lines + 1] = "(none)"
        return table.concat(lines, "\n") .. "\n"
    end
    table.sort(rows, function(a, b) return tostring(a.id) < tostring(b.id) end)
    for _idx, r in ipairs(rows) do
        lines[#lines + 1] = string.format(
            "%s  enabled=%s  configured=%s",
            tostring(r.id),
            r.enabled and "yes" or "no",
            r.configured and "yes" or "no"
        )
    end
    return table.concat(lines, "\n") .. "\n"
end

--- 月读书源设置摘要（active / mixed / enabled 集合）。
---@param source table|nil MoonSettings.get("source")
---@return string
function M.moonSourceText(source)
    source = type(source) == "table" and source or {}
    local lines = {
        "active_source: " .. tostring(source.active_source or "?"),
        "library_mixed: " .. tostring(source.library_mixed == true),
        "enabled_sources:",
    }
    local enabled = source.enabled_sources
    if type(enabled) ~= "table" then
        lines[#lines + 1] = "  (nil = all enabled by default)"
    else
        local ids = {}
        for id, on in pairs(enabled) do
            ids[#ids + 1] = { id = tostring(id), on = on ~= false }
        end
        table.sort(ids, function(a, b) return a.id < b.id end)
        if #ids == 0 then
            lines[#lines + 1] = "  (empty table)"
        else
            for _idx, row in ipairs(ids) do
                lines[#lines + 1] = string.format("  %s = %s", row.id, row.on and "true" or "false")
            end
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

--- 书库规模：总数 + 按源 + 已读/未读。
---@param info { total: integer|nil, by_source: { source_id: string, count: integer }[]|nil, read: integer|nil, unread: integer|nil, hidden: integer|nil, deleted: integer|nil }
---@return string
function M.libraryText(info)
    info = info or {}
    local lines = {
        "library scale (deleted=0 hidden=0 unless noted):",
        "total: " .. tostring(info.total or 0),
        "read: " .. tostring(info.read or 0),
        "unread: " .. tostring(info.unread or 0),
        "hidden: " .. tostring(info.hidden or 0),
        "tombstone_deleted: " .. tostring(info.deleted or 0),
        "",
        "by source:",
    }
    local rows = info.by_source or {}
    if #rows == 0 then
        lines[#lines + 1] = "  (none)"
    else
        for _idx, r in ipairs(rows) do
            lines[#lines + 1] = string.format("  %s: %d", tostring(r.source_id), tonumber(r.count) or 0)
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

--- 设备事实（型号 / 平台 / 屏幕 / 存储 / 联网）。
---@param info table|nil
---@return string
function M.deviceText(info)
    info = info or {}
    local lines = {
        "device:",
        "model: " .. tostring(info.model or "?"),
        "platform: " .. tostring(info.platform or "?"),
        "screen: " .. tostring(info.screen_w or "?") .. "x" .. tostring(info.screen_h or "?"),
        "dpi: " .. tostring(info.dpi or "?"),
        "storage_total_bytes: " .. tostring(info.storage_total or "?"),
        "storage_free_bytes: " .. tostring(info.storage_free or "?"),
        "storage_avail_bytes: " .. tostring(info.storage_avail or "?"),
        "network_connected: " .. tostring(info.connected),
        "has_battery: " .. tostring(info.has_battery),
        "battery: " .. tostring(info.battery or "n/a"),
    }
    return table.concat(lines, "\n") .. "\n"
end

--- 当前阅读会话摘要（无书名凭证；路径已托名）。
---@param info table|nil open=false 表示桌面侧
---@param roots { root: string, token: string }[]|nil
---@return string
function M.sessionText(info, roots)
    if not info or not info.open then
        return "current reading session: (none — desktop / file manager)\n"
    end
    local lines = {
        "current reading session:",
        "source_id: " .. tostring(info.source_id or "?"),
        "stable_id: " .. M.scrubPaths(tostring(info.stable_id or "?"), roots),
        "chapter_idx: " .. tostring(info.chapter_idx),
        "file: " .. M.scrubPaths(tostring(info.file or "?"), roots),
        "view_mode: " .. tostring(info.view_mode or "?"),
        "page: " .. tostring(info.page or "?") .. " / " .. tostring(info.total_pages or "?"),
        "percent: " .. tostring(info.percent or "?"),
        "copt_status_line: " .. tostring(info.copt_status_line),
        "header_height: " .. tostring(info.header_height),
    }
    return table.concat(lines, "\n") .. "\n"
end

--- 各源脏行计数（只记条数，不落内容）。
---@param rows { id: string, books: integer, notes: integer, progress: integer, stats: integer }[]|nil
---@return string
function M.dirtyText(rows)
    local lines = {
        "dirty rows (sync_status=0 counts only; no payloads):",
        "",
    }
    if not rows or #rows == 0 then
        lines[#lines + 1] = "(none)"
        return table.concat(lines, "\n") .. "\n"
    end
    table.sort(rows, function(a, b) return tostring(a.id) < tostring(b.id) end)
    local any = false
    for _idx, r in ipairs(rows) do
        local sum = (r.books or 0) + (r.notes or 0) + (r.progress or 0) + (r.stats or 0)
        if sum > 0 then any = true end
        lines[#lines + 1] = string.format(
            "%s  books=%d  notes=%d  progress=%d  stats=%d",
            tostring(r.id), r.books or 0, r.notes or 0, r.progress or 0, r.stats or 0
        )
    end
    if not any then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "(all clean)"
    end
    return table.concat(lines, "\n") .. "\n"
end

--- 各源采样的书 / 章 sdr 正文（路径已托名、内容已脱敏）。
---@param samples { source_id: string, stable_id: string, kind: string, path: string, sdr_path: string|nil, text: string|nil, note: string|nil }[]|nil
---@param heading string|nil
---@return string
function M.sdrSamplesText(samples, heading)
    local lines = {
        heading or "sidecar (.sdr) samples:",
        "paths scrubbed; secrets redacted; credentials never included.",
        "",
    }
    if not samples or #samples == 0 then
        lines[#lines + 1] = "(no samples)"
        return table.concat(lines, "\n") .. "\n"
    end
    for _idx, s in ipairs(samples) do
        lines[#lines + 1] = string.format(
            "==== %s  %s  stable_id=%s ====",
            tostring(s.source_id), tostring(s.kind), tostring(s.stable_id)
        )
        lines[#lines + 1] = "doc: " .. tostring(s.path)
        lines[#lines + 1] = "sdr: " .. tostring(s.sdr_path or "(missing)")
        if s.note then lines[#lines + 1] = "note: " .. s.note end
        if s.text and s.text ~= "" then
            lines[#lines + 1] = "-- begin --"
            lines[#lines + 1] = s.text
            if s.text:sub(-1) ~= "\n" then lines[#lines + 1] = "" end
            lines[#lines + 1] = "-- end --"
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

--- 读文件（可选上限）；超限截尾。
---@param path string
---@param limit number|nil
---@return string|nil
---@return string|nil note
local function readCapped(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil, "unreadable" end
    local size = f:seek("end") or 0
    limit = limit or M.SDR_MAX
    local truncated = size > limit
    f:seek("set", truncated and (size - limit) or 0)
    local text = f:read("*a") or ""
    f:close()
    if truncated then
        text = text:gsub("^[^\n]*\n", "", 1)
        return text, "truncated to last " .. tostring(limit) .. " bytes"
    end
    return text, nil
end

--- 读某文档的 sidecar，返回已托名/脱敏的采样行。
---@param roots { root: string, token: string }[]
---@param source_id string
---@param stable_id string
---@param kind string
---@param doc_path string
---@param DocSettings table
---@return table
local function sdrSample(roots, source_id, stable_id, kind, doc_path, DocSettings)
    local scrubbed_doc = M.scrubPaths(doc_path, roots)
    local scrubbed_sid = M.scrubPaths(tostring(stable_id), roots)
    local sdr = DocSettings:findSidecarFile(doc_path)
    if not sdr then
        return {
            source_id = source_id, stable_id = scrubbed_sid, kind = kind,
            path = scrubbed_doc, sdr_path = nil, note = "no sidecar",
        }
    end
    local text, note = readCapped(sdr, M.SDR_MAX)
    return {
        source_id = source_id, stable_id = scrubbed_sid, kind = kind,
        path = scrubbed_doc,
        sdr_path = M.scrubPaths(sdr, roots),
        text = text and M.redact(M.scrubPaths(text, roots)) or nil,
        note = note or (text and nil or "unreadable"),
    }
end

--- 现场采集诊断 extras（失败只记 notes，不抛）。
---@return { name: string, text: string }[]
---@return string[]
function M.gatherExtras()
    local extras, notes = {}, {}
    local roots = M.pathRoots()

    local function add(name, text)
        extras[#extras + 1] = { name = name, text = text or "" }
    end
    local function try(label, fn)
        local ok, a, b = pcall(fn)
        if not ok then
            notes[#notes + 1] = "diag failed (" .. label .. "): " .. tostring(a)
            return nil
        end
        return a, b
    end

    -- 0) 设备事实
    try("device", function()
        local Device = require("device")
        local DataStorage = require("datastorage")
        local platforms = {}
        for _idx, name in ipairs({
            "isKindle", "isKobo", "isAndroid", "isPocketBook", "isCervantes",
            "isRemarkable", "isSonyPRSTUX", "isSDL",
        }) do
            local fn = Device[name]
            local ok, v = pcall(function() return fn and fn(Device) end)
            if ok and v then
                platforms[#platforms + 1] = name:match("^is(.+)$"):lower()
            end
        end
        local total, free, avail = require("ffi/util").df(DataStorage:getDataDir())
        local connected
        do
            local ok_n, v = pcall(function() return require("ui/network/manager"):isConnected() end)
            connected = ok_n and v == true
        end
        local battery
        if Device:hasBattery() and Device.powerd then
            battery = Device.powerd:getCapacity()
        end
        add("diag/device.txt", M.deviceText({
            model = Device.model,
            platform = #platforms > 0 and table.concat(platforms, ",") or "unknown",
            screen_w = Device.screen and Device.screen:getWidth(),
            screen_h = Device.screen and Device.screen:getHeight(),
            dpi = Device.screen and Device.screen:getDPI(),
            storage_total = total,
            storage_free = free,
            storage_avail = avail or free,
            connected = connected,
            has_battery = Device:hasBattery() and true or false,
            battery = battery,
        }))
    end)

    -- 1) 启用插件
    try("plugins", function()
        local PluginLoader = require("pluginloader")
        local enabled, disabled = PluginLoader.enabled_plugins, PluginLoader.disabled_plugins
        if (not enabled or not disabled) and PluginLoader.loadPlugins then
            enabled, disabled = PluginLoader:loadPlugins()
        end
        add("diag/plugins.txt", M.pluginsText(enabled, disabled))
    end)

    -- 2) KOReader 全局设置（值脱敏 + 路径托名）
    try("koreader-settings", function()
        local data = G_reader_settings and G_reader_settings.data
        add("diag/koreader-settings.txt", M.dumpTable(data, roots))
    end)

    -- 3) 源登录态（只写 configured）
    local credential_ids = { zlib = true, opds = true }
    try("accounts", function()
        local Registry = require("source.registry")
        local rows = {}
        for _idx, meta in ipairs(Registry.list()) do
            credential_ids[meta.id] = true
            local configured = false
            local source = select(1, Registry.create(meta.id))
            if source then
                local ok_c, conf = pcall(function() return source:configured() end)
                configured = ok_c and conf == true
                pcall(function() source:close() end)
            end
            rows[#rows + 1] = {
                id = meta.id,
                enabled = Registry.isEnabled(meta.id),
                configured = configured,
            }
        end
        add("diag/accounts.txt", M.accountsText(rows))
    end)

    -- 4) 月读设置：书源摘要 + settings 目录（源凭证文件只列名）
    try("moon-source", function()
        local MoonSettings = require("utils.settings")
        add("diag/moon-source.txt", M.moonSourceText(MoonSettings.get("source")))
    end)
    try("moon-settings", function()
        local Paths = require("utils.paths")
        local lfs = require("libs/libkoreader-lfs")
        local dir = Paths.settingsDir()
        local lines = {
            "moon settings directory: " .. M.scrubPaths(dir, roots),
            "source/store credential files listed as present only (content omitted).",
            "",
        }
        local names = {}
        local ok_d, iter, state = pcall(lfs.dir, dir)
        if ok_d and iter then
            for name in iter, state do
                if name:match("%.lua$") then names[#names + 1] = name end
            end
        else
            lines[#lines + 1] = "(settings dir missing)"
            add("diag/moon-settings.txt", table.concat(lines, "\n") .. "\n")
            return
        end
        table.sort(names)
        for _idx, name in ipairs(names) do
            local id = name:match("^(.*)%.lua$")
            local path = dir .. "/" .. name
            if credential_ids[id] then
                lines[#lines + 1] = "==== " .. name .. " (credential file, content omitted) ===="
                lines[#lines + 1] = "present: yes"
                lines[#lines + 1] = ""
            else
                local text, note = readCapped(path, M.SDR_MAX)
                lines[#lines + 1] = "==== " .. name .. " ===="
                if note then lines[#lines + 1] = "note: " .. note end
                if text then
                    lines[#lines + 1] = M.redact(M.scrubPaths(text, roots))
                    if text:sub(-1) ~= "\n" then lines[#lines + 1] = "" end
                else
                    lines[#lines + 1] = "(unreadable)"
                    lines[#lines + 1] = ""
                end
            end
        end
        add("diag/moon-settings.txt", table.concat(lines, "\n"))
    end)

    -- 5) 书库规模
    try("library", function()
        local BookDB = require("book.books_db")
        local Registry = require("source.registry")
        local ids = {}
        for _idx, meta in ipairs(Registry.list()) do ids[#ids + 1] = meta.id end
        if #ids == 0 then ids = { "local" } end
        local by_source = BookDB.sourceCountsBySource(ids)
        local total = 0
        for _idx, r in ipairs(by_source) do total = total + (tonumber(r.count) or 0) end
        local status = BookDB.readStatusCountsBySource(ids)
        local read, unread = 0, 0
        for _idx, r in ipairs(status) do
            if r.status == "read" then read = r.count end
            if r.status == "unread" then unread = r.count end
        end
        local hidden = BookDB.hiddenCountBySource(ids)
        local deleted = tonumber(require("utils.db").rowexec(
            "SELECT COUNT(*) FROM books WHERE deleted=1;"
        )) or 0
        add("diag/library.txt", M.libraryText({
            total = total, by_source = by_source, read = read, unread = unread,
            hidden = hidden, deleted = deleted,
        }))
    end)

    -- 5b) 脏行计数
    try("dirty", function()
        local Registry = require("source.registry")
        local DB = require("utils.db")
        local function count(sql, id)
            return tonumber(DB.rowexec(sql, id)) or 0
        end
        local rows = {}
        for _idx, meta in ipairs(Registry.list()) do
            rows[#rows + 1] = {
                id = meta.id,
                books = count("SELECT COUNT(*) FROM books WHERE source_id=? AND sync_status=0;", meta.id),
                notes = count("SELECT COUNT(*) FROM notes WHERE source_id=? AND sync_status=0;", meta.id),
                progress = count("SELECT COUNT(*) FROM pending_progress WHERE source_id=? AND sync_status=0;", meta.id),
                stats = count("SELECT COUNT(*) FROM reading_stats WHERE source_id=? AND sync_status=0;", meta.id),
            }
        end
        add("diag/dirty.txt", M.dirtyText(rows))
    end)

    -- 6) 当前阅读会话 + 其 sdr
    try("session", function()
        local session = require("reader.session").current()
        if not session or not session.identity then
            add("diag/session.txt", M.sessionText({ open = false }, roots))
            return
        end
        local id = session.identity
        local ui = session.ui
        local doc = ui and ui.document
        local file = doc and doc.file
        local view_mode = ui and ui.view and ui.view.view_mode
        local copt = ui and ui.doc_settings and ui.doc_settings:readSetting("copt_status_line")
        local header
        if doc and doc.getHeaderHeight then
            local ok_h, h = pcall(function() return doc:getHeaderHeight() end)
            if ok_h then header = h end
        end
        add("diag/session.txt", M.sessionText({
            open = true,
            source_id = id.source_id,
            stable_id = id.stable_id,
            chapter_idx = id.chapter_idx,
            file = file,
            view_mode = view_mode,
            page = session.page,
            total_pages = session.total_pages,
            percent = session.percent,
            copt_status_line = copt,
            header_height = header,
        }, roots))
        if file then
            local DocSettings = require("docsettings")
            local DB = require("utils.db")
            local samples = {
                sdrSample(roots, id.source_id, id.stable_id, "current", file, DocSettings),
            }
            -- 章会话：当前文件就是章；再抽同书另一章作对照。整书：抽登记过的章 sdr。
            local ch, cn = DB.query(
                [[SELECT path FROM chapters WHERE source_id=? AND stable_id=? AND path!=? ORDER BY chapter_idx ASC LIMIT ?;]],
                id.source_id, id.stable_id, file, M.CHAPTERS_PER_BOOK
            )
            for j = 1, cn do
                samples[#samples + 1] = sdrSample(
                    roots, id.source_id, id.stable_id, "chapter", ch[1][j], DocSettings)
            end
            add("diag/sdr-current.txt", M.sdrSamplesText(samples, "current session sidecar (.sdr):"))
        end
    end)

    -- 7) 最近打开（KOReader history）
    try("sdr-recent", function()
        local ReadHistory = require("readhistory")
        pcall(function() ReadHistory:_read() end)
        local DocSettings = require("docsettings")
        local Store = require("book.store")
        local samples, seen = {}, {}
        local hist = ReadHistory.hist or {}
        local n = 0
        for _idx, item in ipairs(hist) do
            if n >= M.RECENT_HISTORY then break end
            local file = item.file
            if file and file ~= "" and not seen[file] then
                seen[file] = true
                n = n + 1
                local identity = Store.identityFor(file)
                local source_id = identity and identity.source_id or "?"
                local stable_id = identity and identity.stable_id or file
                samples[#samples + 1] = sdrSample(
                    roots, source_id, stable_id, "recent-" .. tostring(n), file, DocSettings)
            end
        end
        add("diag/sdr-recent.txt", M.sdrSamplesText(samples, "recently opened sidecar (.sdr):"))
    end)

    -- 8) 各源采样书 / 章 sdr（补漏：history 没覆盖到的源）
    try("sdr-samples", function()
        local DB = require("utils.db")
        local DocSettings = require("docsettings")
        local result, nrows = DB.query([[
SELECT source_id, stable_id, path FROM books
 WHERE deleted=0 AND path IS NOT NULL AND path != ''
 ORDER BY source_id ASC, inserted_at DESC;
]])
        local per, samples = {}, {}
        for i = 1, nrows do
            local source_id, stable_id, path = result[1][i], result[2][i], result[3][i]
            local n = per[source_id] or 0
            if n < M.SAMPLE_PER_SOURCE then
                per[source_id] = n + 1
                samples[#samples + 1] = sdrSample(roots, source_id, stable_id, "book", path, DocSettings)
                local ch, cn = DB.query(
                    [[SELECT path FROM chapters WHERE source_id=? AND stable_id=? ORDER BY chapter_idx ASC LIMIT ?;]],
                    source_id, stable_id, M.CHAPTERS_PER_BOOK
                )
                for j = 1, cn do
                    samples[#samples + 1] = sdrSample(
                        roots, source_id, stable_id, "chapter", ch[1][j], DocSettings)
                end
            end
        end
        add("diag/sdr-samples.txt", M.sdrSamplesText(samples, "per-source sidecar (.sdr) samples:"))
    end)

    return extras, notes
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
    lines[#lines + 1] = "Secrets (tokens, keys, passwords, cookies, account ids) are redacted as ***;"
    lines[#lines + 1] = "absolute paths scrubbed to $MOON/$DATA/$HOME; source credential files omitted."
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
