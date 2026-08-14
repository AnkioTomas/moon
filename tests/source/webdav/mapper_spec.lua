--[[--
source.webdav.mapper 离线用例

@module tests.source.webdav.mapper_spec
--]]

local Assert = require("support.assert")
local Mapper = require("source.webdav.mapper")

do
    local list = Mapper.list({
        { name = "a.epub", path = "books/a.epub", is_dir = false },
        { name = "notes", path = "books/notes", is_dir = true },
        { name = "readme.txt", path = "books/readme.txt", is_dir = false },
        { name = "x.pdf", path = "books/x.pdf", is_dir = false },
    })
    Assert.eq(#list.data, 3)
    Assert.eq(list.data[1].ref.source_id, "webdav")
    Assert.eq(list.data[1].ref.stable_id, "books/a.epub")
    Assert.is_nil(list.data[1].id)
end
