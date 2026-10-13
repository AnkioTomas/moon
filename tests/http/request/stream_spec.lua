--[[-- http.request.stream：无 Turbo 时 on_done 报错；cancel 可用。 --]]

local Assert = require("support.assert")

local Request = require("http.request")
local Turbo = require("http.turbo")

-- Turbo 不可用：下一 tick 失败，cancel 是空操作
do
    local orig = Turbo.acquire
    Turbo.acquire = function() return nil, "boom" end
    local done_err
    local job = Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })
    Assert.is_nil(done_err)
    require("support.stubs").flush()
    Assert.eq(done_err, "网络组件加载失败：boom")
    job.cancel()
    Turbo.acquire = orig
end

-- loop 已占但 HTTPClient 初始化失败：必须 on_done 收口。
do
    package.loaded["turbo"] = nil
    package.preload["turbo"] = function()
        return {
            ioloop = {
                IOLoop = function()
                    return {
                        add_callback = function(_, fn)
                            local co = coroutine.create(fn)
                            local ok, future = coroutine.resume(co)
                            if not ok then error(future) end
                            if coroutine.status(co) == "suspended" then
                                assert(coroutine.resume(co, future))
                            end
                        end,
                    }
                end,
            },
            async = {
                HTTPClient = function()
                    error("turbo load failed")
                end,
            },
        }
    end

    local done_err
    Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })

    package.preload["turbo"] = nil
    package.loaded["turbo"] = nil
    Assert.matches(tostring(done_err), "turbo load failed")
end

-- 301/302 跟随后不得把中间响应当最终错误。
do
    local UIManager = require("ui/uimanager")
    UIManager.setInputTimeout = function() end
    UIManager.resetInputTimeout = function() end

    local responses = {
        first = { code = 302 },
        second = { code = 200, length = "2" },
        empty = { code = 302, length = "0" },
        missing = { code = 404, length = "3" },
    }
    local first_hop = "first"
    package.preload["turbo.httputil"] = function()
        return {
            hdr_t = { HTTP_RESPONSE = 1 },
            HTTPParser = function(data)
                local response = responses[data]
                return {
                    get_status_code = function() return response.code end,
                    get = function(_, name)
                        if name == "Content-Length" and response.length then
                            return response.length, 99
                        end
                    end,
                }
            end,
        }
    end
    package.preload["turbo.structs.buffer"] = function()
        return function() return {} end
    end
    package.preload["turbo"] = function()
        local methods = {}
        function methods:_chunked_data() end
        function methods:_handle_body(data)
            self.payload = data
            self:_finalize_request()
        end
        -- 与 turbo 一致：跟随跳转时不收尾；否则在 finalize 里同步唤醒等待中的协程并交出响应。
        function methods:_finalize_request()
            local code = self.response_headers:get_status_code()
            if code == 302 and self.kwargs.allow_redirects then
                self.redirect = self.redirect + 1
                return self:_handle_headers("second")
            end
            assert(coroutine.resume(self.future.co, { code = code }))
        end
        local function newClient()
            local client = setmetatable({ redirect = 0 }, { __index = methods })
            client.iostream = {
                read_bytes = function(_, count, callback, arg, streaming, streaming_arg)
                    local data = string.rep("x", count)
                    if streaming then
                        if streaming_arg then
                            streaming(streaming_arg, data)
                        else
                            streaming(data)
                        end
                    end
                    callback(arg, streaming and "" or data)
                end,
                read_until_close = function() end,
                closed = function() return false end,
                close = function() end,
            }
            -- 响应在协程让出之后才到（start 由 ioloop 桩在 yield 后调用）。
            function client:fetch(_, opts)
                self.kwargs = opts
                self.future = { start = function() self:_handle_headers(first_hop) end }
                return self.future
            end
            return client
        end
        return {
            log = { categories = {} },
            ioloop = {
                IOLoop = function()
                    return {
                        add_callback = function(_, fn)
                            local co = coroutine.create(fn)
                            local ok, future = coroutine.resume(co)
                            if not ok then error(future) end
                            future.co = co
                            future.start()
                        end,
                    }
                end,
            },
            async = {
                HTTPClient = newClient,
                errors = { NO_HEADERS = 1, PARSE_ERROR_HEADERS = 2 },
            },
        }
    end

    -- loop 与 turbo 模块在 http.turbo 里一起缓存：换桩后要重载。
    for _idx, name in ipairs({ "http.request", "http.request.stream", "http.request.fetch", "http.turbo" }) do
        package.loaded[name] = nil
    end
    Request = require("http.request")

    local codes, chunks, done_err = {}, {}, "unset"
    Request.stream({ url = "https://example.test/file", allow_redirects = true }, {
        on_headers = function(code) codes[#codes + 1] = code end,
        on_data = function(chunk) chunks[#chunks + 1] = chunk end,
        on_done = function(err) done_err = err end,
    })
    Assert.eq(codes[1], 302)
    Assert.eq(codes[2], 200)
    Assert.eq(table.concat(chunks), "xx")
    Assert.is_nil(done_err)

    -- 不跟随的 302 + Content-Length: 0：当场收尾，不等 keep-alive 连接关闭。
    first_hop = "empty"
    local empty_err = "unset"
    Request.stream({ url = "https://example.test/cover" }, {
        on_done = function(err) empty_err = err end,
    })
    Assert.eq(empty_err, "HTTP 302")

    -- 404 带错误页 body：必须报错，不能把错误页当成功下载（WebDAV 开书曾把 404 页存成书）。
    first_hop = "missing"
    local missing_err, missing_chunks = "unset", {}
    Request.stream({ url = "https://example.test/gone.azw3" }, {
        on_data = function(chunk) missing_chunks[#missing_chunks + 1] = chunk end,
        on_done = function(err) missing_err = err end,
    })
    Assert.eq(missing_err, "HTTP 404")

    local dest = require("support.config").dir() .. "/stream-404.azw3"
    os.remove(dest)
    local dl_ok, dl_err
    Request.download({ url = "https://example.test/gone.azw3" }, dest, function(ok, err) dl_ok, dl_err = ok, err end)
    Assert.is_false(dl_ok)
    Assert.eq(dl_err, "HTTP 404")
    Assert.is_nil(io.open(dest, "rb"), "错误页不落盘")
    Assert.is_nil(io.open(dest .. ".part", "rb"))

    -- on_headers 抛错同 on_data：经 guard 报告，丢弃 body，on_done 报错收口（否则跳过 release，泵不拆）。
    local guard = package.loaded["ui.guard"]
    local reported = {}
    package.loaded["ui.guard"] = {
        call = function(label, fn, ...)
            local ok, ret = pcall(fn, ...)
            if ok then return ret end
            reported[#reported + 1] = label
        end,
    }
    first_hop = "second"
    local header_err, header_chunks = "unset", {}
    Request.stream({ url = "https://example.test/file" }, {
        on_headers = function() error("boom") end,
        on_data = function(chunk) header_chunks[#header_chunks + 1] = chunk end,
        on_done = function(err) header_err = err end,
    })
    Assert.eq(reported[1], "http stream headers")
    Assert.len(header_chunks, 0)
    Assert.eq(header_err, "stream callback failed")
    package.loaded["ui.guard"] = guard

    for _idx, name in ipairs({ "turbo", "turbo.httputil", "turbo.structs.buffer" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end
