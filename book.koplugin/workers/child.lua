--[[--
常驻 Worker 子进程循环。

子进程只处理纯 Lua table 请求；handler 必须是白名单映射，不能从 IPC 接收函数。
这里故意不 require utils.task，也不触碰 UIManager。

@module koplugin.book.workers.child
--]]

local Posix = require("ffi/posix")
local Protocol = require("workers.protocol")

local Child = {}

local function writeFrame(fd, value)
    local frame = Protocol.encode(value)
    local ffi = require("ffi")
    local ptr = ffi.cast("const char *", frame)
    -- 子进程写端是阻塞 fd；Posix.write 会处理 short write，避免大响应被截断。
    local n = Posix.write(fd, ptr, #frame, true)
    if n ~= #frame then error("worker child: pipe write failed") end
end

local function readExact(fd, size)
    local ffi = require("ffi")
    local buffer = ffi.new("char[?]", size)
    local n = Posix.read(fd, buffer, size, true)
    return ffi.string(buffer, n)
end

local function readFrame(fd)
    local header = readExact(fd, 8)
    if #header == 0 then
        return nil, "eof"
    end
    local size = tonumber(header, 16)
    if not size or size > Protocol.MAX_FRAME then
        return nil, "worker child: invalid frame length"
    end
    local payload = readExact(fd, size)
    local decoder = Protocol.newDecoder()
    local messages, err = Protocol.feed(decoder, string.format("%08x", size) .. payload)
    if not messages or #messages ~= 1 then
        return nil, err or "worker child: invalid frame"
    end
    return messages[1]
end

---@param read_fd number
---@param write_fd number
---@param handlers table<string, fun(args: table|nil): any>
function Child.run(read_fd, write_fd, handlers)
    handlers = handlers or {}
    writeFrame(write_fd, { type = "ready" })

    local cancelled = {}
    while true do
        local message, err = readFrame(read_fd)
        if not message then
            if err ~= "eof" then
                pcall(writeFrame, write_fd, {
                    type = "fatal",
                    error = tostring(err),
                })
            end
            return
        end

        if message.type == "shutdown" then
            pcall(writeFrame, write_fd, { type = "stopped" })
            return
        elseif message.type == "cancel" then
            if message.id ~= nil then
                cancelled[message.id] = true
            end
        elseif message.type == "request" then
            local id = message.id
            if cancelled[id] then
                cancelled[id] = nil
                writeFrame(write_fd, { type = "response", id = id, ok = false, error = "cancelled" })
            else
                local handler = handlers[message.op]
                local ok, result
                if type(handler) ~= "function" then
                    ok, result = false, "unknown worker operation: " .. tostring(message.op)
                else
                    ok, result = pcall(handler, message.args)
                end
                writeFrame(write_fd, {
                    type = "response",
                    id = id,
                    ok = ok,
                    result = ok and result or nil,
                    error = ok and nil or tostring(result),
                })
            end
        else
            writeFrame(write_fd, {
                type = "error",
                error = "unknown worker message: " .. tostring(message.type),
            })
        end
    end
end

return Child
