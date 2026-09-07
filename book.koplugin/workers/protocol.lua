--[[--
Worker IPC：8 位十六进制长度 + JSON。半包必须拼，不能假设一次 read 就是一帧。

@module koplugin.book.workers.protocol
--]]

local JSON = require("json")

local Protocol = {}
Protocol.MAX_FRAME = 4 * 1024 * 1024

---@param value table
---@return string
function Protocol.encode(value)
    local ok, payload = pcall(JSON.encode, value)
    if not ok or type(payload) ~= "string" then
        error("worker protocol: encode failed: " .. tostring(payload), 2)
    end
    if #payload > Protocol.MAX_FRAME then
        error("worker protocol: frame too large", 2)
    end
    return string.format("%08x", #payload) .. payload
end

---@return { buffer: string }
function Protocol.newDecoder()
    return { buffer = "" }
end

---@param decoder { buffer: string }
---@param bytes string
---@return table[]|nil messages, string|nil err
function Protocol.feed(decoder, bytes)
    if type(bytes) ~= "string" then
        return nil, "worker protocol: bytes must be string"
    end
    decoder.buffer = decoder.buffer .. bytes
    local out = {}
    while #decoder.buffer >= 8 do
        local size = tonumber(decoder.buffer:sub(1, 8), 16)
        if not size or size < 0 or size > Protocol.MAX_FRAME then
            return nil, "worker protocol: invalid frame length"
        end
        if #decoder.buffer < size + 8 then
            break
        end
        local payload = decoder.buffer:sub(9, size + 8)
        decoder.buffer = decoder.buffer:sub(size + 9)
        local ok, value = pcall(JSON.decode, payload)
        if not ok or type(value) ~= "table" then
            return nil, "worker protocol: invalid JSON payload"
        end
        out[#out + 1] = value
    end
    if #decoder.buffer > Protocol.MAX_FRAME + 8 then
        return nil, "worker protocol: frame too large"
    end
    return out
end

---@param decoder { buffer: string }
---@return boolean, string|nil
function Protocol.finish(decoder)
    if decoder.buffer ~= "" then
        return false, "worker protocol: incomplete frame"
    end
    return true
end

return Protocol
