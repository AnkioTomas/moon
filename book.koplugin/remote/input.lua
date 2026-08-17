--[[--
远程输入 / 共享剪贴板路由（均复用 server 状态机，首参 self=server，不反向 require）：

- /api/input     —— 输入框通道：GET → { active, text }（激活状态+全文，供光标预览）；
                    POST → addChars 光标处追加注入（保留撤销/重绘路径，语义不变）。
- /api/clipboard —— 共享剪贴板：GET → { text }（设备最后复制的文本：阅读划线复制、
                    链接复制等都会落进来）；POST → 整段写入设备剪贴板 + 同步进
                    激活输入框（无激活输入框只写剪贴板，不报错）。空 body = 清空。

body 复用 server 状态机的增量读取（text_mode 攒内存不落盘，上限 256KB——
一段文本足够），完成后由 server._readBody 调对应 handler。

@module koplugin.book.remote.input
--]]

local JSON = require("json")

local Input = {}

--- text_mode body 上限（字节）
Input.TEXT_LIMIT = 256 * 1024

--- 校验 POST body 长度并切到 body 状态；text_mode 落路由标记，供收尾分发。
---@return true|nil|false true=有 body 进状态机；false=空 body，调用方当场收尾；
---        nil=已排错误响应（411/413），调用方直接 return
local function acceptText(self, conn, headers, text_mode)
    local len = tonumber(headers["content-length"] or "")
    if not len or len < 0 then
        self:_fail(conn, 411, "Content-Length required")
        return nil
    end
    if len > Input.TEXT_LIMIT then
        self:_fail(conn, 413, "Text too large")
        return nil
    end
    if len == 0 then
        return false
    end
    conn.text_mode = text_mode
    conn.text_buf = {}
    conn.remaining = len
    conn.state = "body"
    return true
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
    local st = acceptText(self, conn, headers, "append")
    if st == nil then
        return
    end
    if st then
        return true
    end
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
    local st = acceptText(self, conn, headers, "clipboard")
    if st == nil then
        return
    end
    if st then
        return true
    end
    self.handlers.set_clipboard("")
    return self:_queueResponse(conn, {
        code = 200, ctype = "application/json; charset=utf-8", body = '{"ok":true}',
    })
end

return Input
