--[[--
屏幕镜像只读路由：GET /api/screen 返回当前屏幕 PNG，If-None-Match 命中返回 304；
POST /api/screen?x=&y=&kind=tap|hold|swipe（swipe 另带 dir=north|south|east|west&dist=像素）在屏幕像素坐标注入触摸手势。

@module koplugin.book.features.remote.screen
--]]

local Screen = {}

local DIRS = { north = true, south = true, east = true, west = true }

---@param conn table
---@param method string
---@param headers table
---@param query table
function Screen.route(self, conn, method, headers, query)
    if method == "POST" then
        local x, y = tonumber(query.x), tonumber(query.y)
        local dist = tonumber(query.dist)
        if not x or not y or (query.kind ~= "tap" and query.kind ~= "hold" and query.kind ~= "swipe")
            or (query.kind == "swipe" and (not DIRS[query.dir] or not dist)) then
            return self:_fail(conn, 400, "bad touch")
        end
        local ok, code, msg = self.handlers.send_touch(x, y, query.kind, query.dir, dist)
        if not ok then
            return self:_fail(conn, code, msg)
        end
        return self:_json(conn, 200, '{"ok":true}')
    end
    if method ~= "GET" then
        return self:_fail(conn, 405, "Method Not Allowed")
    end
    local png, tag, msg = self.handlers.get_screen(headers["if-none-match"])
    if not png then
        if tag == 304 then
            return self:_queueResponse(conn, { code = 304, extra = { 'ETag: ' .. headers["if-none-match"] } })
        end
        return self:_fail(conn, tag --[[@as number]], msg)
    end
    return self:_queueResponse(conn, {
        code = 200,
        ctype = "image/png",
        body = png,
        extra = { "ETag: " .. tag, "Cache-Control: no-cache" },
    })
end

return Screen
