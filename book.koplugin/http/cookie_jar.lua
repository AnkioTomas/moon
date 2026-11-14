--[[--
进程内 Cookie 罐（RFC 6265 的够用子集，行为对齐浏览器）：Domain / Path / Secure / Expires / Max-Age。

经 `Request.request`（get/post 同走）的 `opts.jar` 使用：发请求前按 URL 自动带 `Cookie`（调用方显式写了
`Cookie` 头则不覆盖），回包的全部 `Set-Cookie` 自动收进来。只活在内存，不落盘；落盘的登录凭据仍归各源设置。
`seed` 灌入用户保存的「name=value; …」串：无 Domain / 不限路径，对任何 host 生效。
陈旧回包保护：请求发出时记下 `jar.seq`，回包里的 Cookie 若在此之后已被别的响应改过同一条则丢弃。
重定向的中间跳 Set-Cookie 由 Turbo 吞掉，收不到；需要的源自己 `allow_redirects=false` 手动跟。

@module koplugin.book.http.cookie_jar
--]]

---@class CookieEntry
---@field name string
---@field value string
---@field domain string|nil nil = 不限 host（seed）
---@field host_only boolean
---@field path string
---@field secure boolean
---@field expires number|nil epoch 秒
---@field created integer 首次写入序号
---@field touched integer 最近写入序号（对照 jar.seq）

---@class CookieJar
---@field seq integer
---@field entries table<string, CookieEntry>
local Jar = {}
Jar.__index = Jar

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }

--- "Wed, 21 Oct 2015 07:28:00 GMT" → epoch（不碰本地时区）。认不出返回 nil。
---@param text string
---@return number|nil
local function parseDate(text)
    local day, mon, year, h, m, s = text:match("(%d+)[%s%-]+(%a+)[%s%-]+(%d+)%s+(%d+):(%d+):(%d+)")
    mon = mon and MONTHS[mon:sub(1, 3):lower()]
    if not mon then return nil end
    year = tonumber(year)
    if year < 70 then year = year + 2000 elseif year < 100 then year = year + 1900 end
    -- days-from-civil
    local y = mon <= 2 and year - 1 or year
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (mon + (mon > 2 and -3 or 9)) + 2) / 5) + tonumber(day) - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

---@param url string
---@return string scheme, string host, string path
local function split(url)
    local scheme, host, rest = url:match("^(%a[%w+.-]*)://([^/?#]*)(.*)$")
    host = (host or ""):gsub("^.*@", ""):gsub(":%d+$", ""):lower()
    local path = (rest or ""):match("^([^?#]*)")
    if not path or path == "" then path = "/" end
    return (scheme or ""):lower(), host, path
end

---@param path string 请求路径
---@param cookie_path string
local function pathMatch(path, cookie_path)
    if path == cookie_path then return true end
    if path:sub(1, #cookie_path) ~= cookie_path then return false end
    return cookie_path:sub(-1) == "/" or path:sub(#cookie_path + 1, #cookie_path + 1) == "/"
end

---@param host string
---@param entry CookieEntry
local function domainMatch(host, entry)
    if not entry.domain then return true end
    if host == entry.domain then return true end
    return not entry.host_only and host:sub(-#entry.domain - 1) == "." .. entry.domain
end

---@return CookieJar
function Jar.new()
    return setmetatable({ seq = 0, entries = {} }, Jar)
end

---@param entry CookieEntry
function Jar:_set(entry)
    local key = entry.name .. "\0" .. (entry.domain or "") .. "\0" .. entry.path
    local old = self.entries[key]
    self.seq = self.seq + 1
    entry.created = old and old.created or self.seq
    entry.touched = self.seq
    self.entries[key] = entry
end

--- 灌入保存的 Cookie 请求头串（name=value; …），对任何 host、任何路径生效。
---@param text string|nil
---@return CookieJar self
function Jar:seed(text)
    for name, value in (text or ""):gmatch("([^=;%s]+)=([^;]*)") do
        self:_set({ name = name, value = value, host_only = false, path = "/", secure = false })
    end
    return self
end

--- 收一批 Set-Cookie 行。
---@param url string 产生这些响应的请求 URL
---@param lines string[]
---@param since integer|nil 请求发出时的 jar.seq；之后又被改过的同一条 Cookie 不覆盖
function Jar:absorb(url, lines, since)
    local _scheme, host, dir = split(url)
    local now = os.time()
    for _idx, line in ipairs(lines) do
        local pair, attrs = line:match("^%s*([^;]*)(.*)$")
        local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if name then
            local entry = { name = name, value = value, domain = host, host_only = true, secure = false }
            local max_age
            for key, val in attrs:gmatch(";%s*([^=;%s]+)%s*=?%s*([^;]*)") do
                key = key:lower()
                if key == "domain" then
                    val = val:gsub("^%.", ""):lower()
                    if val ~= "" then entry.domain, entry.host_only = val, false end
                elseif key == "path" then
                    if val:sub(1, 1) == "/" then entry.path = val end
                elseif key == "max-age" then
                    max_age = tonumber(val)
                elseif key == "expires" then
                    entry.expires = parseDate(val)
                elseif key == "secure" then
                    entry.secure = true
                end
            end
            if max_age then entry.expires = now + max_age end
            if not entry.path then
                entry.path = dir:match("^(.*)/[^/]*$")
                if not entry.path or entry.path == "" then entry.path = "/" end
            end
            -- 浏览器拒收与请求 host 不相干的 Domain
            if domainMatch(host, entry) then
                local key = name .. "\0" .. entry.domain .. "\0" .. entry.path
                local old = self.entries[key]
                local seeded = self.entries[name .. "\0\0/"]
                if not (since and old and old.touched > since) then
                    -- 站点下发的同名 Cookie 顶替用户保存的那份（seed 没有 host，等于「就是这个站的」）
                    if seeded then self.entries[name .. "\0\0/"] = nil end
                    if entry.expires and entry.expires <= now then
                        self.entries[key] = nil
                        self.seq = self.seq + 1
                    else
                        self:_set(entry)
                    end
                end
            end
        end
    end
end

--- 该 URL 应带的 Cookie 请求头值；没有返回 nil。路径长者在前，同路径先建者在前。
---@param url string
---@return string|nil
function Jar:header(url)
    local scheme, host, path = split(url)
    local now = os.time()
    local picked = {}
    for key, entry in pairs(self.entries) do
        if entry.expires and entry.expires <= now then
            self.entries[key] = nil
        elseif domainMatch(host, entry) and pathMatch(path, entry.path)
            and (not entry.secure or scheme == "https") then
            picked[#picked + 1] = entry
        end
    end
    table.sort(picked, function(a, b)
        if #a.path ~= #b.path then return #a.path > #b.path end
        return a.created < b.created
    end)
    local out = {}
    for _idx, entry in ipairs(picked) do
        out[#out + 1] = entry.name .. "=" .. entry.value
    end
    return #out > 0 and table.concat(out, "; ") or nil
end

---@type table<string, { cookie: string, jar: CookieJar }>
local sessions = {}

--- 某个源某份登录 Cookie 的会话罐：同一份 Cookie 复用同一个罐（服务端轮换的会话留在罐里），
--- 换了 Cookie（换号 / 重新登录）就重建，不继承旧会话。
---@param id string 源 id
---@param cookie string|nil 已保存的 Cookie 串；nil / 空返回 nil（匿名请求不带罐）
---@return CookieJar|nil
function Jar.session(id, cookie)
    if type(cookie) ~= "string" or cookie == "" then return nil end
    local held = sessions[id]
    if not held or held.cookie ~= cookie then
        held = { cookie = cookie, jar = Jar.new():seed(cookie) }
        sessions[id] = held
    end
    return held.jar
end

--- 按名取当前值（任意 host / 路径，同名取最新写入的一条）。
---@param name string
---@return string|nil
function Jar:get(name)
    local best
    for _key, entry in pairs(self.entries) do
        if entry.name == name and (not entry.expires or entry.expires > os.time())
            and (not best or entry.touched > best.touched) then
            best = entry
        end
    end
    return best and best.value
end

return Jar
