--[[--
从话题页的 `window.__NUXT__` 里拆目录。

网页把接口响应编成一个函数调用：结构留在函数体，字符串和数字落在参数上。
章节数组是 `comics:[{id:`，作者昵称是函数体里唯一的 `.nickname="..."` 赋值。

@module source.kuaikan.page
--]]

local Page = {}
local JSON = require("json")

--- 参数位置上的对象 / null。不能把 nil 塞进数组，否则后面的参数整体错位。
local HOLE = {}

---@param source string
---@param index integer
---@return integer
local function skip(source, index)
    return (source:match("^%s*()", index)) or index
end

---@param source string
---@param index integer 引号所在位置
---@return string|nil
---@return integer|nil
local function readString(source, index)
    local quote = source:sub(index, index)
    local cursor = index + 1
    while cursor <= #source do
        local char = source:sub(cursor, cursor)
        if char == "\\" then
            cursor = cursor + 2
        elseif char == quote then
            local literal = source:sub(index, cursor)
            if quote ~= '"' then
                literal = '"' .. literal:sub(2, -2):gsub("\\'", "'"):gsub('"', '\\"') .. '"'
            end
            local ok, value = pcall(JSON.decode, literal)
            if not ok or type(value) ~= "string" then return nil end
            return value, cursor + 1
        else
            cursor = cursor + 1
        end
    end
    return nil
end

--- 跳过从 index 开始的引号字符串，返回结束后的位置。
---@param source string
---@param index integer
---@return integer|nil
local function skipString(source, index)
    local _text, next_index = readString(source, index)
    return next_index
end

--- 配平 `{}` / `[]`，字符串里的括号不算。
---@param source string
---@param index integer
---@return integer|nil
local function matchBlock(source, index)
    local depth = 0
    while index <= #source do
        local char = source:sub(index, index)
        if char == '"' or char == "'" then
            index = skipString(source, index)
            if not index then return nil end
        elseif char == "{" or char == "[" then
            depth = depth + 1
            index = index + 1
        elseif char == "}" or char == "]" then
            depth = depth - 1
            index = index + 1
            if depth == 0 then return index end
        else
            index = index + 1
        end
    end
    return nil
end

---@param source string
---@param index integer
---@param env table<string, any>
---@return any
---@return integer|nil
local function readValue(source, index, env)
    index = skip(source, index)
    local char = source:sub(index, index)
    if char == '"' or char == "'" then return readString(source, index) end
    if char == "{" or char == "[" then return nil, matchBlock(source, index) end
    local ident = source:match("^[%a_$][%w_$]*", index)
    if ident then
        local after = index + #ident
        if source:sub(after, after) == "(" then
            local close = source:find(")", after + 1, true)
            if not close then return nil end
            return nil, close + 1
        end
        if ident == "true" then return true, after end
        if ident == "false" then return false, after end
        if ident == "null" or ident == "undefined" then return nil, after end
        return env[ident], after
    end
    local number = source:match("^-?%d+%.?%d*", index)
    if number then return tonumber(number), index + #number end
    return nil, index
end

---@param source string
---@param index integer 指向 `{`
---@param env table<string, any>
---@return table|nil
---@return integer|nil
local function readObject(source, index, env)
    index = index + 1
    local fields = {}
    while index <= #source do
        index = skip(source, index)
        if source:sub(index, index) == "}" then return fields, index + 1 end
        local key = source:match("^[%w_]+", index)
        if not key then return nil end
        index = index + #key
        if source:sub(index, index) ~= ":" then return nil end
        local value, next_index = readValue(source, index + 1, env)
        if not next_index or next_index <= index then return nil end
        fields[key] = value
        index = skip(source, next_index)
        if source:sub(index, index) == "," then
            index = index + 1
        elseif source:sub(index, index) ~= "}" then
            return nil
        end
    end
    return nil
end

---@param source string
---@param index integer 指向 `(`
---@return any[]|nil
local function readArgs(source, index)
    index = index + 1
    local args = {}
    while index <= #source do
        index = skip(source, index)
        if source:sub(index, index) == ")" then return args end
        local value, next_index = readValue(source, index, {})
        if not next_index or next_index <= index then return nil end
        args[#args + 1] = value == nil and HOLE or value
        index = skip(source, next_index)
        local separator = source:sub(index, index)
        if separator == "," then index = index + 1
        elseif separator ~= ")" then return nil end
    end
    return nil
end

---@param script string
---@return table<string, any>|nil
local function bind(script)
    local params_at = script:find("function(", 1, true)
    if not params_at then return nil end
    local params_end = script:find(")", params_at + 9, true)
    if not params_end then return nil end
    local params = {}
    for name in script:sub(params_at + 9, params_end - 1):gmatch("[%a_$][%w_$]*") do
        params[#params + 1] = name
    end
    local body_at = skip(script, params_end + 1)
    if script:sub(body_at, body_at) ~= "{" then return nil end
    local after_body = matchBlock(script, body_at)
    if not after_body then return nil end
    local args_at = skip(script, after_body)
    if script:sub(args_at, args_at) ~= "(" then return nil end
    local args = readArgs(script, args_at)
    if not args then return nil end
    local env = {}
    for index, name in ipairs(params) do
        local value = args[index]
        if value ~= HOLE and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
            env[name] = value
        end
    end
    return env
end

--- 拆话题页。失败返回 nil。
---@param html string|nil
---@return { info: table, nickname: string, chapters: table[] }|nil
function Page.topic(html)
    if type(html) ~= "string" then return nil end
    local at = html:find("window.__NUXT__=", 1, true)
    if not at then return nil end
    local script = html:sub(at)
    local env = bind(script)
    if not env then return nil end

    local info_at = script:find("topicInfo:{", 1, true)
    local info = {}
    if info_at then
        local object = readObject(script, info_at + #"topicInfo:" , env)
        if object then info = object end
    end

    local comics_at = script:find("comics:[{id:", 1, true)
    if not comics_at then return nil end
    local cursor = script:find("{", comics_at, true)
    local chapters = {}
    while cursor and script:sub(cursor, cursor) == "{" do
        local row, next_cursor = readObject(script, cursor, env)
        if not row then return nil end
        if row.id == nil or type(row.title) ~= "string" or row.title == "" then return nil end
        chapters[#chapters + 1] = {
            id = row.id,
            title = row.title,
            locked = row.locked == true,
        }
        cursor = skip(script, next_cursor)
        if script:sub(cursor, cursor) == "," then
            cursor = skip(script, cursor + 1)
        elseif script:sub(cursor, cursor) == "]" then
            break
        else
            return nil
        end
    end
    if #chapters == 0 or script:sub(cursor, cursor) ~= "]" then return nil end

    local nickname_at = script:find('%.nickname="')
    local nickname = nickname_at and readString(script, nickname_at + #".nickname=")
    return {
        info = info,
        nickname = nickname or "",
        chapters = chapters,
    }
end

return Page
