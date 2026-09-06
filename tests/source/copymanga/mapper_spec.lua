--[[--
拷贝漫画数据映射用例。

@module tests.source.copymanga.mapper_spec
--]]

local Assert = require("support.assert")
local Mapper = require("source.copymanga.mapper")

do
    local result = Mapper.search({
        results = {
            total = 1,
            list = {{
                name = "测试漫画",
                path_word = "test-comic",
                cover = "https://img.example/cover.jpg",
                author = { { name = "作者甲" }, { name = "作者乙" } },
            }},
        },
    })
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].source_id, "copymanga")
    Assert.eq(result.data[1].stable_id, "test-comic")
    Assert.eq(result.data[1].authors, "作者甲, 作者乙")
end

do
    local wire = {
        results = {
            comic = {
                uuid = "comic-uuid-1",
                name = "测试漫画",
                path_word = "test-comic",
                cover = "https://img.example/cover.jpg",
                author = { { name = "作者甲" } },
                theme = { { name = "冒險" } },
                brief = "第一行第二行",
            },
        },
    }
    Assert.eq(Mapper.comicId(wire), "comic-uuid-1")
    Assert.is_nil(Mapper.comicId({ results = { comic = { name = "无id" } } }))
    local book = Mapper.detail("test-comic", wire)
    Assert.eq(book.title, "测试漫画")
    Assert.eq(book.authors, "作者甲")
    Assert.eq(book.category, "冒險")
    Assert.eq(book.intro, "第一行第二行")
    Assert.eq(book.cover, "https://img.example/cover.jpg")
end

do
    local groups = Mapper.groups({
        results = {
            groups = {
                extra = { name = "番外", path_word = "extra" },
                default = { name = "默认", path_word = "default" },
            },
        },
    })
    Assert.len(groups, 2)
    Assert.eq(groups[1].path_word, "default")
    Assert.eq(groups[2].path_word, "extra")
end

do
    local groups = Mapper.groups({ results = {} })
    Assert.len(groups, 1)
    Assert.eq(groups[1].path_word, "default")
end

do
    local chapters = Mapper.chapters({
        { uuid = "uuid-1", name = "第一話", group_path = "default", group_name = "默认" },
        { uuid = "uuid-2", name = "第二話", group_path = "default", group_name = "默认" },
        { uuid = "uuid-1", name = "第一話", group_path = "default", group_name = "默认" },
        { uuid = "uuid-x", name = "番外1", group_path = "extra", group_name = "番外" },
    })
    Assert.len(chapters, 3)
    Assert.eq(chapters[1].idx, 1)
    Assert.eq(chapters[1].uid, "uuid-1")
    Assert.eq(chapters[2].title, "第二話")
    Assert.eq(chapters[3].title, "番外 · 番外1")
end

do
    local result = Mapper.collect({
        results = {
            total = 1,
            list = {{
                comic = {
                    name = "收藏漫画",
                    path_word = "fav-comic",
                    cover = "https://img.example/fav.jpg",
                    author = { { name = "作者丙" } },
                },
            }},
        },
    })
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].stable_id, "fav-comic")
    Assert.eq(result.data[1].title, "收藏漫画")
    Assert.eq(result.data[1].authors, "作者丙")
    Assert.is_true(result.data[1].in_library)
end
