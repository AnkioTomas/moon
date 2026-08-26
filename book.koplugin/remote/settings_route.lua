--[[--
远程配置路由：GET/POST /api/settings。

@module koplugin.book.remote.settings_route
--]]

local JSON = require("json")
local SettingsApi = require("remote.settings")

local Route = {}

Route.BODY_LIMIT = SettingsApi.BODY_LIMIT

--- /api/settings body 收尾：JSON 部分更新
function Route.finishSettings(self, conn, text)
    local payload, err = JSON.decode(text)
    if not payload then
        return self:_fail(conn, 400, err or "invalid json")
    end
    local applied
    applied, err = SettingsApi.apply(payload)
    if not applied then
        return self:_fail(conn, 400, err)
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "application/json; charset=utf-8",
        body = JSON.encode(applied),
    })
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
    local st = self:_acceptText(conn, headers, Route.BODY_LIMIT, Route.finishSettings)
    if st == nil then
        return
    end
    if st then
        return true
    end
    -- 空 body = 空 JSON 部分更新
    return Route.finishSettings(self, conn, "{}")
end

return Route
