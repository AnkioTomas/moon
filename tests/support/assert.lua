--[[--
最小断言库（零依赖）。

@module tests.support.assert
--]]

local Assert = {}

local function fmt(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

---@param cond any
---@param msg string|nil
function Assert.is_true(cond, msg)
    if not cond then
        error(msg or "expected true", 2)
    end
end

---@param cond any
---@param msg string|nil
function Assert.is_false(cond, msg)
    if cond then
        error(msg or "expected false", 2)
    end
end

---@param a any
---@param b any
---@param msg string|nil
function Assert.eq(a, b, msg)
    if a ~= b then
        error((msg or "eq") .. ": " .. fmt(a) .. " ~= " .. fmt(b), 2)
    end
end

---@param v any
---@param msg string|nil
function Assert.is_nil(v, msg)
    if v ~= nil then
        error((msg or "expected nil") .. ": got " .. fmt(v), 2)
    end
end

---@param v any
---@param msg string|nil
function Assert.not_nil(v, msg)
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

return Assert
