--[[--
流式 HTTP：body 到达即 on_data，结束时 on_done(err)。用于 SSE / chunked / 下载。

对外经 `Request.stream(opts, handlers) → { cancel }`，不要直接 require。

@module koplugin.book.http.request.stream
--]]

local Fetch = require("http.request.fetch")
local Turbo = require("http.turbo")
local T = require("ffi/util").template
local _ = require("gettext")

local Stream = {}

--- 官方 turbo 会把整段 body 攒内存（SSE/大文件会炸），这里只改读路径：
--- 有长度走 iostream 增量回调，chunked 不入 _read_buffer，无长度按连接关闭读；301/302 先收尾再跟下一跳。
---@param opts HttpRequest
---@param handlers HttpStreamHandlers
---@return HttpJob
function Stream.open(opts, handlers)
    local ctx, begin_err = Fetch.begin(opts, "book.http stream")
    if not ctx then
        return handlers.on_done and Fetch.fail("http stream", handlers.on_done, begin_err) or Fetch.NOOP
    end
    local state = { cancelled = false, done = false }
    local received = 0

    --- 只回调一次 on_done。on_done 后再 release，方便连环开流；回调经 guard，抛错也一定 release。
    ---@param err any nil 表示正常收完
    local function finish(err)
        if state.done then
            return
        end
        state.done = true
        state.client = nil
        err = state.data_err or err
        Fetch.log(ctx, err, "bytes", received)
        if handlers.on_done then Fetch.call("http stream", handlers.on_done, err) end
        Turbo.release()
    end

    --- 已取消或已结束后一律丢弃；非字符串或空串忽略。on_data 抛过错就丢弃后续块，免得每块都再报一次。
    local function emit(chunk)
        if state.cancelled or state.done or state.data_err or type(chunk) ~= "string" or #chunk == 0 then
            return
        end
        received = received + #chunk
        if handlers.on_data and not Fetch.call("http stream data", function()
            handlers.on_data(chunk)
            return true
        end) then
            state.data_err = "stream callback failed"
        end
    end

    ctx.loop:add_callback(function()
        if state.cancelled then
            return finish("cancelled")
        end
        local client, client_err = Turbo.client()
        if not client then
            return finish(client_err)
        end
        local errors = require("turbo").async.errors
        local httputil = require("turbo.httputil")
        local buffer = require("turbo.structs.buffer")
        state.client = client

        client._chunked_data = function(self, data)
            if data and data:len() > 2 then
                emit(data:sub(1, data:len() - 2))
            end
            self.iostream:read_until("\r\n", self._handle_chunked_encoding, self)
        end

        --- 读完 body 后统一收尾（payload 置空：数据已经 emit 出去了）。
        local function complete(self_)
            self_.payload = ""
            self_:_finalize_request()
        end

        client._handle_headers = function(self, data)
            if not data then
                return self:_throw_error(errors.NO_HEADERS,
                    "No data receive after connect. Expected HTTP headers.")
            end
            local parsed, headers = xpcall(httputil.HTTPParser, function() end,
                data, httputil.hdr_t["HTTP_RESPONSE"])
            if not parsed then
                return self:_throw_error(errors.PARSE_ERROR_HEADERS,
                    "Could not parse HTTP response header")
            end
            self.response_headers = headers
            local code = headers:get_status_code()
            if not state.cancelled and handlers.on_headers and not Fetch.call("http stream headers", function()
                handlers.on_headers(code, headers)
                return true
            end) then
                state.data_err = "stream callback failed"
            end
            if opts.allow_redirects and (code == 301 or code == 302) then
                return self:_finalize_request()
            end
            local transfer = headers:get("Transfer-Encoding", true)
            if transfer and tostring(transfer):lower() == "chunked" then
                self._chunked = true
                self._read_buffer = buffer()
                return self.iostream:read_until("\r\n", self._handle_chunked_encoding, self)
            end
            -- get() 可能多返回值；第二值进 tonumber 会当成进制。
            local content_length = tonumber((headers:get("Content-Length", true)))
            -- 长度为 0 必须当场收尾：keep-alive 连接不会关，read_until_close 会挂到超时。
            if content_length == 0 then
                return complete(self)
            end
            if content_length then
                return self.iostream:read_bytes(content_length, complete, self, emit)
            end
            self.iostream:read_until_close(function(self_, final_data)
                emit(final_data)
                complete(self_)
            end, self, emit)
        end

        local fetched, future = pcall(client.fetch, client, opts.url, Fetch.options(opts, 6))
        if not fetched then
            return finish(future)
        end
        -- turbo 的 _finalize_request 在最后一跳收尾时同步唤醒这里；跟随跳转的中间响应不会唤醒。
        local res = coroutine.yield(future)
        local err = Fetch.responseError(res)
        if not err and not Fetch.ok(res.code) then err = T(_("HTTP %1"), tostring(res.code)) end
        finish(err)
    end)

    return Fetch.job(state, function()
        Fetch.close(state.client)
        finish("cancelled")
    end)
end

return Stream
