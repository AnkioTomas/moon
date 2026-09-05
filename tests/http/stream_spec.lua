--[[-- http.request.stream：无 Turbo 时 on_done 报错；cancel 可用。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local Request = require("http.request")

-- Turbo 不可用路径
do
    local orig = Request.ensureTurbo
    Request.ensureTurbo = function() return false end
    local done_err
    Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })
    Stubs.flush()
    Assert.eq(done_err, "turbo looper unavailable")
    Request.ensureTurbo = orig
end

-- cancel 在启动前
do
    local orig = Request.ensureTurbo
    Request.ensureTurbo = function() return false end
    local done_err
    local job = Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })
    job.cancel()
    Stubs.flush()
    -- cancel 抢先 finish；或 turbo 不可用回调——两者都可接受已完成
    Assert.is_true(done_err == "cancelled" or done_err == "turbo looper unavailable")
    Request.ensureTurbo = orig
end

-- looper 可用但 Turbo 初始化失败：必须 on_done 收口，不能让输入超时引用泄漏。
do
    local UIManager = require("ui/uimanager")
    local orig = Request.ensureTurbo
    local resets = 0
    Request.ensureTurbo = function() return true end
    UIManager.setInputTimeout = function() end
    UIManager.resetInputTimeout = function() resets = resets + 1 end
    UIManager.looper = {
        add_callback = function(_, fn)
            local co = coroutine.create(fn)
            local ok, err = coroutine.resume(co)
            if not ok then error(err) end
        end,
    }
    package.loaded["turbo"] = nil
    package.preload["turbo"] = function()
        error("turbo load failed")
    end

    local done_err
    Request.stream({ url = "https://example.test/" }, {
        on_done = function(err) done_err = err end,
    })

    Request.ensureTurbo = orig
    package.preload["turbo"] = nil
    package.loaded["turbo"] = nil
    Assert.matches(tostring(done_err), "turbo load failed")
    Assert.eq(resets, 1)
end

-- 301/302 跟随后不得把中间响应当最终错误。
do
    local UIManager = require("ui/uimanager")
    local orig = Request.ensureTurbo
    Request.ensureTurbo = function() return true end
    UIManager.setInputTimeout = function() end
    UIManager.resetInputTimeout = function() end
    UIManager.looper = {
        add_callback = function(_, fn)
            local co = coroutine.create(fn)
            local ok, future = coroutine.resume(co)
            if not ok then error(future) end
            if coroutine.status(co) == "suspended" then
                assert(coroutine.resume(co, future))
            end
        end,
    }

    local responses = {
        first = { code = 302 },
        second = { code = 200, length = "2" },
    }
    package.preload["turbo.httputil"] = function()
        return {
            hdr_t = { HTTP_RESPONSE = 1 },
            HTTPParser = function(data)
                local response = responses[data]
                return {
                    get_status_code = function() return response.code end,
                    get = function(_, name)
                        if name == "Content-Length" then return response.length end
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
        function methods:_finalize_request()
            local code = self.response_headers:get_status_code()
            if code == 302 and self.kwargs.allow_redirects then
                self.redirect = self.redirect + 1
                self:_handle_headers("second")
            end
        end
        local function newClient()
            local client = setmetatable({ redirect = 0 }, { __index = methods })
            client.iostream = {
                read_bytes = function(_, count, callback, arg, streaming, streaming_arg)
                    if streaming then streaming(streaming_arg, string.rep("x", count)) end
                    callback(arg, "")
                end,
                read_until_close = function() end,
                closed = function() return false end,
                close = function() end,
            }
            function client:fetch(_, opts)
                self.kwargs = opts
                self:_handle_headers("first")
                return { code = 200 }
            end
            return client
        end
        return {
            log = { categories = {} },
            async = {
                HTTPClient = newClient,
                errors = { NO_HEADERS = 1, PARSE_ERROR_HEADERS = 2 },
            },
        }
    end

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

    Request.ensureTurbo = orig
    for _, name in ipairs({ "turbo", "turbo.httputil", "turbo.structs.buffer" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end
