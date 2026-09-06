--[[--
京东读书 wire 映射离线用例。

@module tests.source.jdread.mapper_spec
--]]

local Assert = require("support.assert")
local Mapper = require("source.jdread.mapper")

do
    local result = Mapper.shelfList({
        data = {
            total = 1,
            books = {{
                ebook_id = 42,
                name = "测试书",
                author = "作者",
                progress = 0.25,
                image_url = "//example.test/cover.jpg.dpg",
            }},
        },
    })
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].source_id, "jdread")
    Assert.eq(result.data[1].stable_id, "42")
    Assert.eq(result.data[1].title, "测试书")
    Assert.eq(result.data[1].percent, 25)
    Assert.eq(result.data[1].cover, "https://example.test/cover.jpg")
end

do
    local cover_id, cover_url
    local result = Mapper.storeList({
        data = {
            total_count = 1,
            product_search_infos = {{
                product_id = 30533530,
                product_name = "计算机网络",
                author = "陈虹",
                content_info = "简介",
                logo = "https://example.test/store.jpg.dpg",
                cate_third_names = { "网络通信", "教材" },
            }},
        },
    }, function(id, url)
        cover_id, cover_url = id, url
    end)
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].stable_id, "30533530")
    Assert.eq(result.data[1].title, "计算机网络")
    Assert.eq(result.data[1].intro, "简介")
    Assert.eq(result.data[1].category, "网络通信, 教材")
    Assert.eq(cover_id, "30533530")
    Assert.eq(cover_url, "https://example.test/store.jpg")
end

do
    local result = Mapper.shelfList({
        data = {
            books = {{
                ebook_id = 43,
                name = "京东封面",
                image_url = "//img10.360buyimg.com/n12/cover.jpg.dpg",
            }},
        },
    })
    Assert.eq(result.data[1].cover, "https://img10.360buyimg.com/n12/cover.jpg")
end

do
    local toc = Mapper.chapters({
        catalogList = {
            { sort = 2, catalogId = 12, catalogName = "第二节", level = 1 },
            { sort = 1, catalogId = 11, catalogName = "第一章", level = 0 },
        },
    })
    Assert.len(toc, 2)
    Assert.eq(toc[1].uid, "11")
    Assert.eq(toc[1].depth, 1)
    Assert.eq(toc[2].idx, 2)
    Assert.eq(toc[2].depth, 2)
end

do
    local payload = Mapper.content({
        contentList = {
            { content = "<html><body><p>一</p></body></html>" },
            { content = "<p>二</p>" },
        },
    }, "标题")
    Assert.eq(payload.title, "标题")
    Assert.matches(payload.html, "<p>一</p>")
    Assert.matches(payload.html, "<p>二</p>")
end

do
    local pos, uid = Mapper.progress({
        data = {{
            list = {
                { data_type = 1, percent = 0.9, chapter_id = "note", version = 20 },
                {
                    data_type = 0,
                    percent = 0.25,
                    chapter_id = 12,
                    epub_chapter_title = "第二节",
                    version = 21,
                },
            },
        }},
    })
    Assert.eq(pos.fraction, 0.25)
    Assert.eq(pos.chapter_title, "第二节")
    Assert.eq(uid, "12")
end
