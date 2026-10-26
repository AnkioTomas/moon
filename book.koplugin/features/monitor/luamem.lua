--[[--
Lua 堆按模块归属的估算：从每个已加载模块出发遍历可达对象（表、字符串、闭包、upvalue、元表），
先到先得地把对象大小记给第一个碰到它的模块。KOReader 自己的模块先遍历，月读模块后遍历，
所以两边共用的对象算在 KOReader 头上，月读各部分只计自己独有的。

LuaJIT 没有取对象大小的接口，大小按 32 位 LuaJIT 的内存布局估：表头 32 字节 + 数组部分 8 字节/项 +
哈希部分 24 字节/槽（槽数取 2 的幂），字符串 17 字节 + 长度，闭包 20 字节 + 4 字节/upvalue，
函数原型按定义行数估 40 字节/行（每个原型只算一次）。数字是量级参考，不是精确值。
`collectgarbage("count")` 的总量减去归属之和就是「未归属」（全局表、注册表、协程栈、cdata 等）。

@module koplugin.book.features.monitor.luamem
--]]

local LuaMem = {}

local function pow2(n)
    local p = 1
    while p < n do p = p * 2 end
    return p
end

---@param name string
---@param plugin table<string, true> 月读顶层模块名集合
---@return string owner, boolean mine
local function ownerOf(name, plugin)
    local top = name:match("^[^%./]+")
    if not plugin[top] then return "KOReader: " .. top, false end
    local a, b = name:match("^([^%.]+)%.([^%.]+)")
    if a == "features" or a == "source" or a == "store" then return a .. "." .. b, true end
    if a == "ui" and b == "themes" then return "ui.themes", true end
    return top, true
end

--- 遍历 root 可达的、尚未被别人记过的对象，返回估算字节数。
---@param root any
---@param seen table
---@param protos table
---@return integer
local function walk(root, seen, protos)
    local bytes, stack, n = 0, { root }, 1
    local getinfo, getupvalue, getmetatable = debug.getinfo, debug.getupvalue, getmetatable
    while n > 0 do
        local v = stack[n]
        stack[n] = nil
        n = n - 1
        local kind = type(v)
        if kind == "string" then
            if not seen[v] then
                seen[v] = true
                bytes = bytes + 17 + #v
            end
        elseif kind == "table" or kind == "function" then
            if not seen[v] then
                seen[v] = true
                if kind == "table" then
                    local arr, hash = #v, 0
                    for k, val in next, v do
                        n = n + 1
                        stack[n] = k
                        n = n + 1
                        stack[n] = val
                        if not (type(k) == "number" and k >= 1 and k <= arr) then hash = hash + 1 end
                    end
                    bytes = bytes + 32 + arr * 8 + (hash > 0 and pow2(hash) * 24 or 0)
                    local mt = getmetatable(v)
                    if type(mt) == "table" then
                        n = n + 1
                        stack[n] = mt
                    end
                else
                    local info = getinfo(v, "Su")
                    bytes = bytes + 20 + 4 * info.nups
                    local key = info.source .. ":" .. info.linedefined
                    if info.what == "Lua" and not protos[key] then
                        protos[key] = true
                        bytes = bytes + 40 * math.max(1, info.lastlinedefined - info.linedefined)
                    end
                    for i = 1, info.nups do
                        local _name, up = getupvalue(v, i)
                        if not rawequal(up, nil) then
                            n = n + 1
                            stack[n] = up
                        end
                    end
                end
            end
        end
    end
    return bytes
end

--- 估算各模块占用。
---@param plugin table<string, true> 月读顶层模块名集合（目录名与文件名去掉 .lua）
---@return { name: string, kb: integer, mine: boolean, rest?: boolean }[] rows 从大到小；末尾含「未归属」
function LuaMem.scan(plugin)
    collectgarbage()
    collectgarbage()
    local total_kb = collectgarbage("count")
    local seen, protos = {}, {}
    seen[package.loaded] = true
    seen[_G] = true
    seen[seen] = true
    seen[protos] = true

    local names = {}
    for name in pairs(package.loaded) do
        if type(name) == "string" then names[#names + 1] = name end
    end
    table.sort(names, function(a, b)
        local _o1, m1 = ownerOf(a, plugin)
        local _o2, m2 = ownerOf(b, plugin)
        if m1 ~= m2 then return not m1 end
        return a < b
    end)

    local sums, mine = {}, {}
    for _idx, name in ipairs(names) do
        local owner, is_mine = ownerOf(name, plugin)
        sums[owner] = (sums[owner] or 0) + walk(package.loaded[name], seen, protos)
        mine[owner] = is_mine
    end

    local rows, used = {}, 0
    for owner, bytes in pairs(sums) do
        rows[#rows + 1] = { name = owner, kb = math.floor(bytes / 1024), mine = mine[owner] }
        used = used + bytes / 1024
    end
    table.sort(rows, function(a, b) return a.kb > b.kb end)
    rows[#rows + 1] = { name = "", kb = math.max(0, math.floor(total_kb - used)), mine = false, rest = true }
    return rows
end

return LuaMem
