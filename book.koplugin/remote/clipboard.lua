--[[--
共享剪贴板路由。

GET /api/clipboard 返回设备最后复制的文本；POST 整段写入设备剪贴板，并由
handler 决定是否同步到当前输入框。空 body 表示清空。

@module koplugin.book.remote.clipboard
--]]

local JSON = require("json")

local Clipboard = {}

Clipboard.TEXT_LIMIT = 256 * 1024

---@param conn table
---@param text string
function Clipboard.finish(self, conn, text)
    self.handlers.set_clipboard(text)
    return self:_queueResponse(conn, {
        code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
    })
end

---@param conn table
---@param method string
---@param headers table
---@return true|nil
function Clipboard.route(self, conn, method, headers, _query)
    if method == "GET" then
        local st = self.handlers.get_clipboard() or {}
        return self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode({ text = st.text or "" }),
        })
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local state = self:_acceptText(conn, headers, Clipboard.TEXT_LIMIT, Clipboard.finish)
    if state == nil then return end
    if state then return true end
    return Clipboard.finish(self, conn, "")
end

return Clipboard
