--[[--
测试用：请求实际会带的 Cookie 头（显式 Cookie 头，或 opts.jar 按 URL 算出的值）。

@module tests.support.cookie
--]]

return function(request)
    local opts = request.opts
    return opts.headers and opts.headers.Cookie or (opts.jar and opts.jar:header(request.url))
end
