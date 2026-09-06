--[[--
拷贝漫画 chapter2 图片排序用例。

@module tests.source.copymanga.protocol_spec
--]]

local Assert = require("support.assert")
local Protocol = require("source.copymanga.protocol")

do
    local images, err = Protocol.chapterImages({
        results = {
            chapter = {
                contents = {
                    { url = "https://img.example/002.c800x.webp" },
                    { url = "https://img.example/001.c800x.webp" },
                },
                words = { 1, 0 },
            },
        },
    })
    Assert.is_nil(err)
    Assert.len(images, 2)
    Assert.eq(images[1], "https://img.example/001.c1500x.webp")
    Assert.eq(images[2], "https://img.example/002.c1500x.webp")
end

do
    local images, err = Protocol.chapterImages({
        chapter = {
            contents = {
                { url = "https://img.example/001.webp" },
                { url = "https://img.example/002.webp" },
            },
        },
    })
    Assert.is_nil(err)
    Assert.eq(images[1], "https://img.example/001.webp")
    Assert.eq(images[2], "https://img.example/002.webp")
end

do
    local images, err = Protocol.chapterImages({})
    Assert.is_nil(images)
    Assert.eq(err, "chapter payload missing")
end

do
    local images, err = Protocol.chapterImages({
        chapter = { contents = { { url = "not-a-url" } }, words = { 0 } },
    })
    Assert.is_nil(images)
    Assert.eq(err, "chapter images empty")
end
