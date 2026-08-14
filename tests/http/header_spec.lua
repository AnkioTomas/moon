--[[--
http.header 离线用例

@module tests.header_spec
--]]

local Assert = require("support.assert")
local Header = require("http.header")

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
