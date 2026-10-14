--[[--
HTTP Header 拼装（不碰网络）。默认 UA 为 KOReader/MoonBook，extra 可覆盖任意键。

@module koplugin.book.http.request.header
--]]

local USER_AGENT = "KOReader/MoonBook"

local Header = {}

--- 合并 headers；extra 覆盖 defaults，键名不分大小写（保留 extra 的写法）
---@param extra table<string, string>|nil
---@param defaults table<string, string>|nil
---@return table<string, string>
function Header.merge(extra, defaults)
    local headers, names = {}, {}
    for _idx, src in ipairs({ defaults or {}, extra or {} }) do
        for k, v in pairs(src) do
            local lower = k:lower()
            if names[lower] then headers[names[lower]] = nil end
            headers[k], names[lower] = v, k
        end
    end
    return headers
end

--- 普通请求默认头。extra 可覆盖 UA / Accept / 任意自定义头。
---@param extra table|nil
---@param accept string|nil 默认 */*；若 extra 已带 Accept 则以 extra 为准
---@return table
function Header.forRequest(extra, accept)
    return Header.merge(extra, {
        ["Accept"] = accept or "*/*",
        ["User-Agent"] = USER_AGENT,
    })
end

--- 下载默认头。extra 可覆盖 UA / Connection / Accept。
---@param extra table|nil
---@return table
function Header.forDownload(extra)
    return Header.merge(extra, {
        ["Accept"] = "*/*",
        ["User-Agent"] = USER_AGENT,
        ["Connection"] = "close",
    })
end

--- 拆开被合并成一行的多条 Set-Cookie。
--- 只在「逗号 + 空白 + name=」处切，expires=Wed, 21 Oct … 里的逗号后面不是 name=，不会被切开。
---@param line string
---@return string[]
function Header.splitSetCookie(line)
    local out = {}
    if type(line) ~= "string" or line == "" then return out end
    local start, pos = 1, 1
    while true do
        local comma = line:find(",", pos, true)
        if not comma then break end
        local rest = line:sub(comma + 1)
        if rest:match("^%s*[^%s;,=]+=") then
            local part = line:sub(start, comma - 1):match("^%s*(.-)%s*$")
            if part ~= "" then out[#out + 1] = part end
            start = comma + 1
        end
        pos = comma + 1
    end
    local last = line:sub(start):match("^%s*(.-)%s*$")
    if last ~= "" then out[#out + 1] = last end
    return out
end

return Header
