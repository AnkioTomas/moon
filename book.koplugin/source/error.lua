--[[--
Source 结构化错误。上层按 code 分支，禁止解析 message。

@module koplugin.book.source.error
--]]

local SourceError = {}

--- 构造结构化 SourceError。
---@param code "not_configured"|"unauthorized"|"unsupported"|"offline"|"not_found"|"protocol"|"io"
---@param message string
---@param opts { retryable: boolean|nil, cause: string|nil }|nil
---@return SourceError
function SourceError.new(code, message, opts)
    opts = opts or {}
    return {
        code = code,
        message = message,
        retryable = opts.retryable == true,
        cause = opts.cause,
    }
end

--- 从错误对象或字符串取出可读 message。
---@param err SourceError|string|nil
---@return string
function SourceError.message(err)
    if type(err) == "table" and type(err.message) == "string" then
        return err.message
    end
    if type(err) == "string" then
        return err
    end
    return ""
end

--- 从错误对象取出 code；非表则返回 nil。
---@param err SourceError|string|nil
---@return string|nil
function SourceError.code(err)
    if type(err) == "table" then
        return err.code
    end
    return nil
end

--- 构造 unsupported 错误。
---@param message string
---@param cause string|nil
---@return SourceError
function SourceError.unsupported(message, cause)
    return SourceError.new("unsupported", message, { cause = cause })
end

--- 构造 not_configured 错误。
---@param message string
---@param cause string|nil
---@return SourceError
function SourceError.not_configured(message, cause)
    return SourceError.new("not_configured", message, { cause = cause })
end

--- 构造 unauthorized 错误。
---@param message string
---@param cause string|nil
---@return SourceError
function SourceError.unauthorized(message, cause)
    return SourceError.new("unauthorized", message, { cause = cause })
end

--- 构造可重试的 offline 错误。
---@param message string
---@param cause string|nil
---@return SourceError
function SourceError.offline(message, cause)
    return SourceError.new("offline", message, { retryable = true, cause = cause })
end

--- 构造 not_found 错误。
---@param message string
---@param cause string|nil
---@return SourceError
function SourceError.not_found(message, cause)
    return SourceError.new("not_found", message, { cause = cause })
end

--- 构造 protocol 错误。
---@param message string
---@param cause string|nil
---@return SourceError
function SourceError.protocol(message, cause)
    return SourceError.new("protocol", message, { cause = cause })
end

--- 构造 io 错误。
---@param message string
---@param cause string|nil
---@return SourceError
function SourceError.io(message, cause)
    return SourceError.new("io", message, { cause = cause })
end

--- 把底层字符串/表错误收成 SourceError（client 边界用）。
---@param err any
---@param fallback_code SourceErrorCode|nil
---@return SourceError
function SourceError.wrap(err, fallback_code)
    if type(err) == "table" and type(err.code) == "string" and type(err.message) == "string" then
        return err
    end
    local msg = SourceError.message(err)
    if msg == "" then
        msg = "unknown error"
    end
    return SourceError.new(fallback_code or "protocol", msg, {
        retryable = fallback_code == "offline",
        cause = type(err) == "string" and err or nil,
    })
end

return SourceError
