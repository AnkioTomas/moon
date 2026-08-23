--[[--
远程输入 / 共享剪贴板路由（均复用 server 状态机，首参 self=server，不反向 require）：

- /api/input     —— 输入框通道：GET → { active, text }（激活状态+全文，供光标预览）；
                    POST → addChars 光标处追加注入（保留撤销/重绘路径，语义不变）。
- /api/clipboard —— 共享剪贴板：GET → { text }（设备最后复制的文本：阅读划线复制、
                    链接复制等都会落进来）；POST → 整段写入设备剪贴板 + 同步进
                    激活输入框（无激活输入框只写剪贴板，不报错）。空 body = 清空。

POST body 走 server:_acceptText 攒内存不落盘（上限 256KB——一段文本足够），
收齐后由 server._readBody 回调这里挂上的 finish 函数。

@module koplugin.book.remote.input
--]]

local JSON = require("json")

local Input = {}

--- POST body 上限（字节）
Input.TEXT_LIMIT = 256 * 1024

--- /api/input body 收尾：光标处追加注入；无激活输入框 → 409。
function Input.finishAppend(self, conn, text)
    local ok, err = self.handlers.set_input(text)
    if not ok then
        return self:_fail(conn, 409, err)
    end
    return self:_queueResponse(conn, {
        code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
    })
end

--- /api/clipboard body 收尾：剪贴板写入不受输入框影响。
function Input.finishClipboard(self, conn, text)
    self.handlers.set_clipboard(text)
    return self:_queueResponse(conn, {
        code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
    })
end

--- 输入框通道：光标处追加（append 唯一模式，与远程输入初衷一致）
function Input.route(self, conn, method, headers, _query)
    if method == "GET" then
        local st = self.handlers.get_input() or {}
        return self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode({
                active = st.active and true or false,
                text = st.active and st.text or nil,
            }),
        })
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local st = self:_acceptText(conn, headers, Input.TEXT_LIMIT, Input.finishAppend)
    if st == nil then
        return
    end
    if st then
        return true
    end
    -- 空 body = 无操作（追加空串本就无意义，直接 ok）
    return self:_queueResponse(conn, {
        code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
    })
end

--- 共享剪贴板通道：GET 读设备最后复制；POST 写设备剪贴板（+激活输入框）
function Input.clipboard(self, conn, method, headers, _query)
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
    local st = self:_acceptText(conn, headers, Input.TEXT_LIMIT, Input.finishClipboard)
    if st == nil then
        return
    end
    if st then
        return true
    end
    -- 空 body = 清空
    return Input.finishClipboard(self, conn, "")
end

return Input
