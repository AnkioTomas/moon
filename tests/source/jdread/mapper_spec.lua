--[[--
京东读书 wire 映射离线用例。

@module tests.source.jdread.mapper_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Mapper = require("source.jdread.mapper")

-- ebooks/lite 真实行（抓包）
do
    local books = Mapper.shelfList({
        {
            ebook_id = 30451107,
            name = "H5匠人手册：霸屏H5实战解密",
            author = "网易传媒设计中心",
            image_url = "https://img10.360buyimg.com/n12/s280x280_jfs/t1/fb9d03bd56331f5d.jpg.dpg",
            format = "epub",
            cate_second_names = { "计算机" },
            cate_third_names = { "程序设计" },
        },
        { ebook_id = 30394360, name = "无封面无分类" },
    })
    Assert.len(books, 2)
    Assert.eq(books[1].source_id, "jdread")
    Assert.eq(books[1].stable_id, "30451107")
    Assert.eq(books[1].title, "H5匠人手册：霸屏H5实战解密")
    Assert.eq(books[1].authors, "网易传媒设计中心")
    Assert.eq(books[1].category, "程序设计")
    Assert.eq(books[1].cover, "https://img10.360buyimg.com/n12/s280x280_jfs/t1/fb9d03bd56331f5d.jpg")
    Assert.is_nil(books[1].percent)
    Assert.is_nil(books[2].cover)
    Assert.is_nil(books[2].category)
end

do
    Assert.len(Mapper.shelfList({}), 0)
end

-- 旧 cread wire 不再识别
do
    Assert.is_nil(Mapper.chapters({
        catalogList = {{ sort = 1, catalogId = 11, catalogName = "第一章", level = 0 }},
    }))
    Assert.is_nil(Mapper.content({ contentList = {{ content = "<p>一</p>" }} }, "标题"))
end

do
    local payload = Mapper.content({
        data = {
            chapter = {
                { content = "<html><body><p>一</p></body></html>" },
                { content = "<p>二</p>" },
            },
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
    Assert.eq(toc[1].toc_version, 5)
    Assert.eq(toc[2].title, "版权信息")
end

-- 《三盏灯》真实目录（抓包）：正文一个文件，小节 1~9 只是锚点；试读版 x.html 与完整版 x-CD.html 同一文件。
-- 按文件成章，已购取完整版下标；封面图挂首章
do
    local rows = {
        { chapter_index = 0, chapter_name = "封面", chapter_item = "titlepage", is_try = true, is_buy = true,
            chapter_uri = "Text/titlepage.xhtml" },
        { chapter_index = 1, chapter_name = "版权信息", chapter_item = "id22", is_try = true, is_buy = true,
            chapter_uri = "Text/index_split_000.html" },
        { chapter_index = 2, chapter_name = "三盏灯", chapter_item = "id21", is_try = false, is_buy = true,
            chapter_uri = "Text/index_split_001-CD.html" },
        { chapter_index = 3, chapter_name = "1", chapter_item = "id21", anchor = "id_1", is_try = true, is_buy = true,
            chapter_uri = "Text/index_split_001.html#id_1" },
        { chapter_index = 4, chapter_name = "2", chapter_item = "id21", anchor = "id_2", is_try = true, is_buy = true,
            chapter_uri = "Text/index_split_001.html#id_2" },
    }
    for i = 5, 11 do
        rows[#rows + 1] = { chapter_index = i, chapter_name = tostring(i - 2), chapter_item = "id21",
            anchor = "id_" .. (i - 2), is_try = false, is_buy = true,
            chapter_uri = "Text/index_split_001-CD.html#id_" .. (i - 2) }
    end
    local toc = Mapper.chapters({ data = {
        format = "epub",
        image_url = "https://img10.360buyimg.com/n12/s280x280_jfs/cover.jpg.dpg",
        chapter_info = rows,
    } })
    Assert.len(toc, 3)
    Assert.eq(toc[1].title, "封面")
    Assert.eq(toc[1].cover, "https://img10.360buyimg.com/n12/s280x280_jfs/cover.jpg")
    Assert.eq(toc[2].uid, "1")
    Assert.eq(toc[3].title, "三盏灯")
    Assert.eq(toc[3].uid, "2")
    Assert.eq(toc[3].source_idx, "2")
    Assert.is_nil(toc[2].cover)
    Assert.is_nil(toc[2].anchors)
    -- 小节 1~9 挂成章内锚点，点选按 HTML id 定位
    Assert.len(toc[3].anchors, 9)
    Assert.eq(toc[3].anchors[1].title, "1")
    Assert.eq(toc[3].anchors[1].id, "id_1")
    Assert.eq(toc[3].anchors[1].depth, 2)
    Assert.eq(toc[3].anchors[9].id, "id_9")
end

-- 未购买：组内只有试读行可下，取首个试读版；同文件不带锚点的重复行丢弃
do
    local toc = Mapper.chapters({ data = { format = "epub", chapter_info = {
        { chapter_index = 0, chapter_name = "正文", chapter_uri = "Text/a-CD.html", is_try = false, is_buy = false },
        { chapter_index = 1, chapter_name = "1", chapter_uri = "Text/a.html#id_1", anchor = "id_1",
            is_try = true, is_buy = false },
        { chapter_index = 2, chapter_name = "重复", chapter_uri = "Text/a.html", is_try = true, is_buy = false },
        { chapter_index = 3, chapter_name = "后记", chapter_uri = "Text/b.html", is_try = false, is_buy = false },
    } } })
    Assert.len(toc, 2)
    Assert.eq(toc[1].uid, "1")
    Assert.len(toc[1].anchors, 1, "不带锚点的重复行不进章内目录")
    Assert.eq(toc[2].title, "后记")
    Assert.eq(toc[2].uid, "3")
end

-- 封面页空 body：给了封面图就补图，没给保持原样（空串，交给落盘报错）
do
    local wire = { data = { chapter = { { content = "<html><body></body></html>" } } } }
    Assert.eq(Mapper.content(wire, "封面", 'https://img.test/a"b.jpg').html, '<p><img src="https://img.test/a&quot;b.jpg"/></p>')
    Assert.eq(Mapper.content(wire, "封面").html, "")
    local text = Mapper.content({ data = { chapter = { { content = "<html><body><p>正文</p></body></html>" } } } },
        "正文", "https://img.test/a.jpg")
    Assert.matches(text.html, "<p>正文</p>")
    Assert.is_nil(text.html:find("img", 1, true))
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
