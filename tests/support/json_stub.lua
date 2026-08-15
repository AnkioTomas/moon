--[[--
最小 JSON decode（测试用，零依赖）。

全局 json stub 的 decode 会直接报错；需要真实解析响应体的 spec 用：

  package.preload["json"] = function()
      return { decode = require("support.json_stub").decode }
  end

支持对象/数组/字符串（含常见转义）/数字/true/false/null。
@module tests.support.json_stub
--]]

local JsonStub = {}

local function parse(s)
    local pos = 1
    local function skipWs()
        local _, e = s:find("^[ \t\n\r]*", pos)
        pos = (e or pos - 1) + 1
    end
    local parseValue
    local function parseString()
        -- 断言 s:sub(pos, pos) == '"'
        pos = pos + 1
        local buf = {}
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == "\\" then
                local esc = s:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if esc == "u" then
                    local code = tonumber(s:sub(pos + 2, pos + 5), 16) or 0xFFFD
                    -- 只处理 BMP，够用
                    if code < 0x80 then
                        buf[#buf + 1] = string.char(code)
                    elseif code < 0x800 then
                        buf[#buf + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
                    else
                        buf[#buf + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
                    end
                    pos = pos + 6
                else
                    buf[#buf + 1] = map[esc] or esc
                    pos = pos + 2
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end
    local function parseObject()
        pos = pos + 1
        local obj = {}
        skipWs()
        if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
        while true do
            skipWs()
            local key = parseString()
            skipWs()
            if s:sub(pos, pos) ~= ":" then error("expected :") end
            pos = pos + 1
            obj[key] = parseValue()
            skipWs()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1 return obj
            else error("expected , or }") end
        end
    end
    local function parseArray()
        pos = pos + 1
        local arr = {}
        skipWs()
        if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
        while true do
            arr[#arr + 1] = parseValue()
            skipWs()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1 return arr
            else error("expected , or ]") end
        end
    end
    function parseValue()
        skipWs()
        local c = s:sub(pos, pos)
        if c == '"' then return parseString()
        elseif c == "{" then return parseObject()
        elseif c == "[" then return parseArray()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
        else
            local num = s:match("^%-?%d+%.?%d*[eE]?[+%-]?%d*", pos)
            if not num or num == "" then error("invalid value at " .. pos) end
            pos = pos + #num
            return tonumber(num)
        end
    end
    skipWs()
    return parseValue()
end

---@param body any
---@return table
function JsonStub.decode(body)
    if type(body) ~= "string" then error("invalid json") end
    return parse(body)
end

return JsonStub
