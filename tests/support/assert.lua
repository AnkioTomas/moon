--[[--
最小断言库（零依赖）。

带断言计数：runner 每文件核对，0 断言 = 假绿判失败（借鉴 koassistant 的教训）。

@module tests.support.assert
--]]

local Assert = {}

--- 当前文件的断言计数（runner 每 spec 前 reset_count）
Assert.count = 0

function Assert.reset_count()
    Assert.count = 0
end

local function bump()
    Assert.count = Assert.count + 1
end

local function fmt(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

---@param cond any
---@param msg string|nil
function Assert.is_true(cond, msg)
    bump()
    if not cond then
        error(msg or "expected true", 2)
    end
end

---@param cond any
---@param msg string|nil
function Assert.is_false(cond, msg)
    bump()
    if cond then
        error(msg or "expected false", 2)
    end
end

---@param a any
---@param b any
---@param msg string|nil
function Assert.eq(a, b, msg)
    bump()
    if a ~= b then
        error((msg or "eq") .. ": " .. fmt(a) .. " ~= " .. fmt(b), 2)
    end
end

---@param v any
---@param msg string|nil
function Assert.is_nil(v, msg)
    bump()
    if v ~= nil then
        error((msg or "expected nil") .. ": got " .. fmt(v), 2)
    end
end

---@param v any
---@param msg string|nil
function Assert.not_nil(v, msg)
    bump()
    if v == nil then
        error(msg or "expected non-nil", 2)
    end
end

---@param t any
---@param n number
---@param msg string|nil
function Assert.len(t, n, msg)
    Assert.eq(#t, n, msg or "length")
end

--- 字符串匹配 Lua pattern
---@param s any
---@param pattern string
---@param msg string|nil
function Assert.matches(s, pattern, msg)
    bump()
    if type(s) ~= "string" or not s:match(pattern) then
        error((msg or "matches") .. ": " .. fmt(s) .. " !~ " .. fmt(pattern), 2)
    end
end

--- 期望 fn 报错；给 pattern 时错误消息还需匹配
---@param fn fun()
---@param pattern string|nil
---@param msg string|nil
function Assert.errors(fn, pattern, msg)
    bump()
    local ok, err = pcall(fn)
    if ok then
        error((msg or "errors") .. ": expected error, got none", 2)
    end
    if pattern and not tostring(err):match(pattern) then
        error((msg or "errors") .. ": " .. fmt(tostring(err)) .. " !~ " .. fmt(pattern), 2)
    end
end

--- 数组包含元素（== 比较）
---@param t table
---@param v any
---@param msg string|nil
function Assert.contains(t, v, msg)
    bump()
    for _, item in ipairs(t) do
        if item == v then
            return
        end
    end
    error((msg or "contains") .. ": " .. fmt(v) .. " not in array", 2)
end

return Assert
