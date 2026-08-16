--[[--
远程输入路由：GET /api/input 查激活状态；POST /api/input 注入文本。

body 复用 server 状态机的增量读取（text_mode 攒内存不落盘，上限 256KB——
一段文本足够），注入完成后由 server._readBody 调 handlers.set_input。
函数签名对齐 Server 方法（首参 self=server），不反向 require server。

@module koplugin.book.remote.input
--]]

local JSON = require("json")

local Input = {}

--- text_mode body 上限（字节）
Input.TEXT_LIMIT = 256 * 1024

--- GET /api/input → { active }；POST /api/input → 整段文本注入
function Input.route(self, conn, method, headers)
    if method == "GET" then
        local st = self.handlers.get_input() or {}
        return self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode({ active = st.active and true or false }),
        })
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local len = tonumber(headers["content-length"] or "")
    if not len or len < 1 then
        return self:_fail(conn, 411, "Content-Length required")
    end
    if len > Input.TEXT_LIMIT then
        return self:_fail(conn, 413, "Text too large")
    end
    conn.text_mode = true
    conn.text_buf = {}
    conn.remaining = len
    conn.state = "body"
    return true
end

return Input
