--[[--
book.note.normalize 纯计算测试：注解形态按文档类型分派 + 跨端去重。

回归背景：renderable 曾只认字符串 page，于是分页文档（PDF/CBZ/DjVu）的划线
全被判成不可渲染；而 Note.applyLocal 拿合并结果整体覆盖 doc_settings，
等于每次开书就把用户自己的划线删掉。

@module tests.book.note_normalize_spec
--]]

local Assert = require("support.assert")
local Normalize = require("book.note.normalize")

-- 分页文档（PDF/CBZ）：page 是数字，pos0/pos1 是坐标表
local paging_items = {
    {
        page = 12, datetime = "2026-01-01", drawer = "lighten",
        pos0 = { x = 1, y = 2, page = 12 }, pos1 = { x = 3, y = 4, page = 12 },
        text = "带划线",
    },
    { page = 13, datetime = "2026-01-02", text = "纯书签，无 drawer" },
}

-- rolling 文档（EPUB/TXT）：page 是 xpointer，pos0/pos1 是字符串
local rolling_items = {
    {
        page = "/body/DocFragment[3]/body/p[1]/text()[1].0",
        datetime = "2026-01-03", drawer = "lighten",
        pos0 = "/body/DocFragment[3]/body/p[1]/text()[1].0",
        pos1 = "/body/DocFragment[3]/body/p[1]/text()[1].9",
        text = "epub 划线",
    },
}

-- ── 分页文档的本地划线必须保留 ──
do
    local merged = Normalize.merge({}, paging_items, true)
    Assert.len(merged, 2, "分页文档的划线不能被丢弃")
    Assert.eq(merged[1].page, 12)
    Assert.is_true(Normalize.renderable(paging_items[1], true))
    -- 带 drawer 但缺坐标表的仍然不可渲染（drawSavedHighlight 会崩）
    Assert.is_false(Normalize.renderable(
        { page = 5, drawer = "lighten", pos0 = "str", pos1 = "str" }, true))
end

-- ── rolling 文档保持原有约束 ──
do
    Assert.len(Normalize.merge({}, rolling_items, false), 1)
    Assert.is_true(Normalize.renderable(rolling_items[1], false))
    -- 带 drawer 缺 pos0/pos1 → 不可渲染
    Assert.is_false(Normalize.renderable(
        { page = "/body/x", drawer = "lighten" }, false))
end

-- ── 异类不得混入：KOReader 按首条 page 类型判定整个数组归属 ──
do
    Assert.len(Normalize.merge(paging_items, {}, false), 0,
        "数字 page 混进 rolling 文档会让整份注解被搬走")
    Assert.len(Normalize.merge(rolling_items, {}, true), 0,
        "字符串 page 混进 paging 文档同理")
end

-- ── 跨端去重：远端与本地同一条只保留一条 ──
do
    local remote = { {
        page = "/body/a", datetime = "x", text = "同一句", wr_range = "1-5",
        wr_bookmark_id = "wr1",
    } }
    -- 本地副本还没回填 wr_bookmark_id，只能靠 text + range 认出是同一条
    local locals = { { page = "/body/a", datetime = "x", text = "同一句", wr_range = "1-5" } }
    Assert.len(Normalize.merge(remote, locals, false), 1, "同一条划线不应显示两遍")

    -- 本地独有的条目要保留
    local extra = { { page = "/body/b", datetime = "y", text = "本地独有" } }
    Assert.len(Normalize.merge(remote, extra, false), 2)

    -- 微信写入后会重排 wire range；同一位置、同一笔记不能因此保留本地无 id 副本。
    local remote_note = { {
        page = "/body/n", datetime = "r", text = "原文", note = "想法",
        wr_range = "100-102", wr_review_id = "rv1",
    } }
    local local_note = { {
        page = "/body/n", datetime = "l", text = "原文", note = "想法",
        wr_range = "300-302",
    } }
    Assert.len(Normalize.merge(remote_note, local_note, false), 1)
end

-- ── 无选中文本的纯书签不能互相判重 ──
do
    local remote = { { page = "/body/a", datetime = "r", text = "" } }
    local locals = {
        { page = "/body/b", datetime = "l1" },
        { page = "/body/c", datetime = "l2", text = "" },
    }
    Assert.len(Normalize.merge(remote, locals, false), 3,
        "无文本的书签彼此没有区分度，不该被当成同一条")
end

-- ── 本地已同步条目在远端未报时仍保留（宁可漏云端删除，不可清本地）──
do
    local locals = { {
        page = "/body/c", datetime = "z", text = "云端这次没报",
        wr_bookmark_id = "wr9",
    } }
    Assert.len(Normalize.merge({}, locals, false), 1)
    Assert.len(Normalize.merge({
        { wr_snapshot = true, wr_authoritative = true },
    }, locals, false), 0, "完整远端快照缺失的已同步条目必须删除")
    Assert.len(Normalize.merge({
        { wr_snapshot = true, wr_authoritative = true },
    }, {
        { page = "/body/local", datetime = "l", text = "本地新增" },
    }, false), 1, "远端删除不能误伤尚无远端 id 的本地新增")
end

-- ── clean：total_pages 回填与必需字段过滤 ──
do
    local cleaned = Normalize.clean({
        { datetime = "d1", page = 3, text = "ok" },
        { text = "缺 datetime，丢弃" },
        { datetime = "d2", text = "缺定位字段，丢弃" },
    }, 100)
    Assert.len(cleaned, 1)
    Assert.eq(cleaned[1].total_pages, 100)
end

-- ── 本地删除必须留下远端 id；只删 note 不能连划线一起删 ──
do
    local current = Normalize.withDeletions({
        {
            datetime = "old", page = "/body/a", drawer = "lighten",
            note = "旧笔记", wr_bookmark_id = "bm1", wr_review_id = "rv1",
        },
        {
            datetime = "old", page = "/body/b", drawer = "lighten",
            wr_bookmark_id = "bm2",
        },
        {
            datetime = "old", page = "/body/c", drawer = "lighten",
            text = "原文", note = "修改前", wr_review_id = "rv3",
        },
    }, {
        {
            datetime = "new", page = "/body/a", drawer = "lighten",
            wr_bookmark_id = "bm1",
        },
        {
            datetime = "new", page = "/body/c", drawer = "lighten",
            text = "原文", note = "修改后", wr_review_id = "rv3",
        },
    })
    Assert.eq(current[1].wr_review_id, "rv1")
    Assert.is_true(current[1].wr_delete_review)
    Assert.is_true(current[2].wr_update_review)
    Assert.is_true(current[3].wr_deleted)
    Assert.eq(current[3].wr_bookmark_id, "bm2")
    Assert.is_nil(current[3].wr_review_id)
end
