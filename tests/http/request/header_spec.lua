--[[--
http.header 离线用例

@module tests.header_spec
--]]

local Assert = require("support.assert")
local Header = require("http.request.header")

do
    local h = Header.merge({ A = "1", B = nil }, { A = "0", C = "3" })
    Assert.eq(h.A, "1")
    Assert.eq(h.C, "3")
    Assert.is_nil(h.B)
end

do
    local h = Header.forRequest({ Authorization = "Bearer x" }, "application/json")
    Assert.eq(h["Accept"], "application/json")
    Assert.eq(h["User-Agent"], "KOReader/MoonBook")
    Assert.eq(h["Authorization"], "Bearer x")
end

do
    local h = Header.forDownload()
    Assert.eq(h["Connection"], "close")
    Assert.eq(h["User-Agent"], "KOReader/MoonBook")
end

-- extra 覆盖默认 UA / Accept / Connection
do
    local h = Header.forRequest({
        ["User-Agent"] = "CustomUA/1",
        ["Accept"] = "text/plain",
    }, "application/json")
    Assert.eq(h["User-Agent"], "CustomUA/1")
    Assert.eq(h["Accept"], "text/plain")
end

do
    local h = Header.forDownload({
        ["User-Agent"] = "DL/9",
        ["Connection"] = "keep-alive",
    })
    Assert.eq(h["User-Agent"], "DL/9")
    Assert.eq(h["Connection"], "keep-alive")
end

-- HTTP 头大小写不敏感；不同大小写覆盖时不能留下两个冲突字段。
do
    local h = Header.forRequest({
        ["user-agent"] = "LowerUA/1",
        ["accept"] = "application/json",
    })
    Assert.eq(h["user-agent"], "LowerUA/1")
    Assert.eq(h["accept"], "application/json")
    Assert.is_nil(h["User-Agent"])
    Assert.is_nil(h["Accept"])
end

-- 合并成一行的 Set-Cookie：只在「, name=」处切，expires 里的逗号不切。
do
    local parts = Header.splitSetCookie("a=1; expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, b=2, c=; Max-Age=0")
    Assert.len(parts, 3)
    Assert.eq(parts[1], "a=1; expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/")
    Assert.eq(parts[2], "b=2")
    Assert.eq(parts[3], "c=; Max-Age=0")
    Assert.len(Header.splitSetCookie(nil), 0)
end
