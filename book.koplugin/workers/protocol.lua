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
    local payload = JSON.encode(value)
    if #payload > Protocol.MAX_FRAME then
        error("worker protocol: frame too large", 2)
    end
    return string.format("%08x", #payload) .. payload
end

--- 半包先攒成块，凑够一整帧才拼一次：逐块 `..` 拼 4MB 帧是 O(n²) 的临时字符串。
---@return { buffer: string, parts: string[], pending: integer, need: integer }
function Protocol.newDecoder()
    return { buffer = "", parts = {}, pending = 0, need = 8 }
end

---@param decoder { buffer: string, parts: string[], pending: integer, need: integer }
---@param bytes string
---@return table[]|nil messages, string|nil err
function Protocol.feed(decoder, bytes)
    local parts = decoder.parts
    parts[#parts + 1] = bytes
    decoder.pending = decoder.pending + #bytes
    if #decoder.buffer + decoder.pending < decoder.need then return {} end
    decoder.buffer = decoder.buffer .. table.concat(parts)
    decoder.parts, decoder.pending, decoder.need = {}, 0, 8
    local out = {}
    while #decoder.buffer >= 8 do
        local size = tonumber(decoder.buffer:sub(1, 8), 16)
        if not size or size < 0 or size > Protocol.MAX_FRAME then
            return nil, "worker protocol: invalid frame length"
        end
        if #decoder.buffer < size + 8 then
            decoder.need = size + 8
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
    return out
end

---@param decoder { buffer: string, pending: integer }
---@return boolean, string|nil
function Protocol.finish(decoder)
    if decoder.buffer ~= "" or decoder.pending > 0 then
        return false, "worker protocol: incomplete frame"
    end
    return true
end

return Protocol
