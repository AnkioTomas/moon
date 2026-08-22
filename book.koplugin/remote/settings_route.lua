--[[--
远程配置路由：GET/POST /api/settings，POST /api/settings/rss/opml。

@module koplugin.book.remote.settings_route
--]]

local JSON = require("json")
local SettingsApi = require("remote.settings")

local Route = {}

Route.BODY_LIMIT = SettingsApi.BODY_LIMIT

---@param self table
---@param conn table
---@param headers table
---@param text_mode string
---@return true|nil|false
local function acceptText(self, conn, headers, text_mode)
    local len = tonumber(headers["content-length"] or "")
    if not len or len < 0 then
        self:_fail(conn, 411, "Content-Length required")
        return nil
    end
    if len > Route.BODY_LIMIT then
        self:_fail(conn, 413, "Body too large")
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

--- GET /api/settings ；POST JSON 部分更新
function Route.settings(self, conn, method, headers, _query)
    if method == "GET" then
        return self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode(SettingsApi.snapshot()),
        })
    end
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local st = acceptText(self, conn, headers, "settings")
    if st == nil then
        return
    end
    if st then
        return true
    end
    local applied, err = SettingsApi.apply({})
    if not applied then
        return self:_fail(conn, 400, err)
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode(applied),
    })
end

--- POST /api/settings/rss/opml —— OPML 原文导入（合并去重）
function Route.opml(self, conn, method, headers, _query)
    if method ~= "POST" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local st = acceptText(self, conn, headers, "opml")
    if st == nil then
        return
    end
    if st then
        return true
    end
    local applied, err = SettingsApi.importOpml("")
    if not applied then
        return self:_fail(conn, 400, err)
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode(applied),
    })
end

--- server._readBody 收尾：解析 JSON / OPML 文本
---@param self table
---@param conn table
---@param text string
---@return boolean|nil
function Route.finishBody(self, conn, text, mode)
    if mode == "settings" then
        local payload, err = JSON.decode(text)
        if not payload then
            self:_fail(conn, 400, err or "invalid json")
            return true
        end
        local applied, err = SettingsApi.apply(payload)
        if not applied then
            self:_fail(conn, 400, err)
            return true
        end
        self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode(applied),
        })
        return true
    end
    if mode == "opml" then
        local applied, err = SettingsApi.importOpml(text)
        if not applied then
            self:_fail(conn, 400, err)
            return true
        end
        self:_queueResponse(conn, {
            code = 200,
            ctype = "application/json; charset=utf-8",
            body = JSON.encode(applied),
        })
        return true
    end
    return nil
end

return Route
