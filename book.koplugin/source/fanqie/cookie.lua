--[[--
番茄 Cookie jar：只保留扫码/会话真正用到的两件事。

@module koplugin.book.source.fanqie.cookie
--]]

local Cookie = {}

-- Set-Cookie 标准属性（小写匹配），不得当 cookie 名持久化。
local SET_COOKIE_ATTRS = {
    ["path"] = true, ["domain"] = true, ["expires"] = true, ["max-age"] = true,
    ["secure"] = true, ["httponly"] = true, ["samesite"] = true,
    ["priority"] = true, ["partitioned"] = true, ["comment"] = true,
    ["version"] = true, ["discard"] = true,
}

---@param cookies table|nil
---@return string
function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        parts[#parts + 1] = key .. "=" .. value
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

--- 合并 Set-Cookie 进 jar。兼容 string / 多值 table。
--- Expires 值含逗号，不能直接按逗号切条。
---@param cookies table|nil
---@param set_cookie string|table|nil
---@return table
function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies or {}
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value)
        end
        return cookies
    end
    local sc = tostring(set_cookie)
    local PLACEHOLDER = "\x01"
    sc = sc:gsub("([Ee][Xx][Pp][Ii][Rr][Ee][Ss]=[^,;]-)%,", "%1" .. PLACEHOLDER)
    for seg in sc:gmatch("[^,\r\n]+") do
        seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
        seg = seg:gsub(PLACEHOLDER, ",")
        if seg ~= "" then
            local cookie_name, cookie_value = seg:match("^([^=%s;]+)=([^;]*)")
            if cookie_name and cookie_value then
                if not SET_COOKIE_ATTRS[cookie_name:lower()] then
                    cookies[cookie_name] = cookie_value
                end
            end
        end
    end
    return cookies
end

return Cookie
