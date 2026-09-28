--[[--
原地剥离 Lua 文档注解：`---` 行注释（LuaLS `---@...`、LDoc）与以 `--[[--` 开头的块注释。

普通 `--` 注释保留。被剥离的注释替换为等量换行，行号不变，线上 traceback 仍能对上源码。
剥离前后以 `string.dump(f, true)` 比对字节码，不一致即报错退出——只准删注释，不准动代码。

用法：luajit tools/strip_lua.lua file1.lua [file2.lua ...]
--]]

local function strip(src)
    local out, last, i = {}, 1, 1

    local function blank(s, e)
        out[#out + 1] = src:sub(last, s - 1):gsub("[ \t]+$", "")
        out[#out + 1] = src:sub(s, e):gsub("[^\n]", "")
        last = e + 1
    end

    while true do
        i = src:find("[\"'%[%-]", i)
        if not i then break end
        local c = src:sub(i, i)
        if c == '"' or c == "'" then
            local j = i + 1
            while true do
                local d = src:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == c then
                    break
                elseif d == "" or d == "\n" then
                    error("unterminated string at byte " .. i)
                else
                    j = j + 1
                end
            end
            i = j + 1
        elseif c == "[" then
            local level = src:match("^%[(=*)%[", i)
            if level then
                local _, e = src:find("]" .. level .. "]", i, true)
                i = assert(e, "unterminated long string") + 1
            else
                i = i + 1
            end
        elseif src:sub(i + 1, i + 1) ~= "-" then
            i = i + 1
        else
            local level = src:match("^%-%-%[(=*)%[", i)
            if level then
                local body = i + 4 + #level
                local _, e = src:find("]" .. level .. "]", body, true)
                assert(e, "unterminated long comment")
                if src:sub(body, body + 1) == "--" then blank(i, e) end
                i = e + 1
            else
                local e = (src:find("\n", i, true) or #src + 1) - 1
                if src:sub(i + 2, i + 2) == "-" then blank(i, e) end
                i = e + 1
            end
        end
    end
    out[#out + 1] = src:sub(last)
    return table.concat(out)
end

local before, after = 0, 0
for _, path in ipairs(arg) do
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()

    local ok, res = pcall(strip, src)
    if not ok then error(path .. ": " .. res, 0) end
    local fn_src = assert(loadstring(src, "=" .. path))
    local fn_res = assert(loadstring(res, "=" .. path))
    if string.dump(fn_src, true) ~= string.dump(fn_res, true) then
        error(path .. ": bytecode changed after stripping", 0)
    end

    f = assert(io.open(path, "wb"))
    f:write(res)
    f:close()
    before, after = before + #src, after + #res
end
io.write(string.format("stripped %d files: %d -> %d bytes\n", #arg, before, after))
