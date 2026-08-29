--[[--
双向 Worker IPC 协议：8 位十六进制长度 + JSON payload。

协议是字节流协议，不能假设一次 read 就得到一个完整消息。
本模块只做编码和增量解码，不依赖 KOReader UI 或进程实现。

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

---@return table
function Protocol.newDecoder()
    return { buffer = "" }
end

--- 增量喂入字节并取出完整消息。
---@param decoder table
---@param bytes string
---@return table[]|nil messages, string|nil err
function Protocol.feed(decoder, bytes)
    if type(bytes) ~= "string" then
        return nil, "worker protocol: bytes must be string"
    end
    decoder.buffer = decoder.buffer .. bytes
    local out = {}
    while #decoder.buffer >= 8 do
        local size_text = decoder.buffer:sub(1, 8)
        local size = tonumber(size_text, 16)
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
    -- 只有未消费的前缀才受此限制；一次 read 携带多个完整帧是合法的。
    if #decoder.buffer > Protocol.MAX_FRAME + 8 then
        return nil, "worker protocol: frame too large"
    end
    return out
end

--- 子进程 EOF 时调用；残留字节表示协议损坏。
---@param decoder table
---@return boolean, string|nil
function Protocol.finish(decoder)
    if decoder.buffer ~= "" then
        return false, "worker protocol: incomplete frame"
    end
    return true
end

return Protocol
