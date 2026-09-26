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
    local toc = Mapper.chapters({
        data = {
            format = "epub",
            chapter_info = {
                { chapter_index = 0, chapter_name = "封面", chapter_id = "" },
                { chapter_index = 1, chapter_name = "版权信息", chapter_id = "" },
            },
        },
    })
    Assert.len(toc, 2)
    Assert.eq(toc[1].uid, "0")
    Assert.eq(toc[1].toc_version, 2)
    Assert.eq(toc[2].title, "版权信息")
end

do
    local payload = Mapper.content({
        data = {
            chapter = {{
                chapter_index = 0,
                content = '<?xml version="1.0"?><html><body><p>试读</p></body></html>',
            }},
        },
    }, "封面")
    Assert.eq(payload.title, "封面")
    Assert.matches(payload.html, "<p>试读</p>")
end

do
    Assert.is_nil(Mapper.content({
        data = { chapter = {{ chapter_index = 14, can_read = false, content = "" }} },
    }, "锁章"))
end

-- txt 网文 v2 目录：卷标题（type 0，无 chapter_id）不成章，uid = chapter_id
do
    local toc = Mapper.chapters({
        data = {
            format = "txt",
            chapter_info = {
                { chapter_name = "庆安才子", type = 0, volume_id = "v1", is_try = true },
                { chapter_id = "15001647875062768", chapter_name = "第一章 俊俏少年", type = 1 },
                { chapter_id = "15017997720337259", chapter_name = "", type = 1 },
                { chapter_name = "第二卷", type = 0, volume_id = "v2" },
                { chapter_id = "15039236894456722", chapter_name = "第三章 压寨相公！", type = 1 },
            },
        },
    })
    Assert.len(toc, 3)
    Assert.eq(toc[1].toc_version, 3)
    Assert.eq(toc[1].uid, "15001647875062768")
    Assert.eq(toc[1].title, "第一章 俊俏少年")
    Assert.eq(toc[2].title, "第2章")
    Assert.eq(toc[3].idx, 3)
    Assert.eq(toc[3].uid, "15039236894456722")
end

do
    Assert.is_nil(Mapper.chapters({
        data = { format = "txt", chapter_info = {{ chapter_name = "卷", type = 0, volume_id = "v" }} },
    }))
end

-- txt 网文正文 content_type=net：\r\n 纯文本分段、转义；
-- 京东原文首段无缩进、后续段带全角缩进，统一剥掉交给模板 text-indent
do
    local payload = Mapper.content({
        data = {
            ebook_id = 34265072,
            content_type = "net",
            chapter = {{
                chapter_index = -1,
                chapter_id = "503000000013072393",
                content = "辽人入京<关我>鸟事。\r\n\r\n　　旁边一个中年胖子眼睛一亮。\r\n　 石小凡有些挠头。",
                can_read = true,
            }},
        },
    }, "第一章 楔子")
    Assert.eq(payload.title, "第一章 楔子")
    Assert.eq(payload.html,
        "<p>辽人入京&lt;关我&gt;鸟事。</p>\n<p>旁边一个中年胖子眼睛一亮。</p>\n<p>石小凡有些挠头。</p>")
end

do
    local payload = Mapper.content({
        data = {
            chapter = {{
                content = '<html><body><p class="img_content">'
                    .. '<img alt="" src="https://img30.360buyimg.com/ebookadmin/jfs/x.jpg" '
                    .. 'href="./image/Images/x.jpg"/></p></body></html>',
            }},
        },
    }, "插图")
    Assert.matches(payload.html, 'src="https://img30.360buyimg.com/ebookadmin/jfs/x.jpg"')
    Assert.matches(payload.html, 'href="./image/Images/x.jpg"')
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
