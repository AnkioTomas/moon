--[[--
设备状态只读路由。

@module koplugin.book.remote.status
--]]

local JSON = require("json")

local Status = {}

---@param conn table
---@param method string
function Status.route(self, conn, method)
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode(self.handlers.get_status()),
    })
end

return Status
