--[[--
source.local.mapper 离线用例

目标模块顶部零硬依赖（只 require types 和 gettext）；
insight 在函数内 require("utils.db.book")，
真实实现会开 sqlite，这里用 package.preload 换成可控假库。

formatDuration 是模块内 local 函数，经由 insight 输出的文案间接覆盖。

@module tests.source.local.mapper_spec
--]]

local Assert = require("support.assert")

-- 可控假 books 表：key = source_id .. "\n" .. stable_id
local FakeBooks = {}
package.preload["utils.db.book"] = function()
    return {
        get = function(source_id, stable_id)
            return FakeBooks[source_id .. "\n" .. tostring(stable_id)]
        end,
    }
end

local Mapper = require("source.local.mapper")

-- ===== bookFromRow / list：字段映射 =====

do -- 全字段行 → Book 逐项映射
    local list = Mapper.list({
        {
            stable_id = "/books/三体.epub",
            title = "三体",
            authors = "刘慈欣",
            intro = "科幻小说",
            category = "科幻",
            percent = 42,
        },
    })
    Assert.eq(list.count, 1)
    local b = list.data[1]
    Assert.eq(b.source_id, "local")
    Assert.eq(b.stable_id, "/books/三体.epub")
    Assert.eq(b.title, "三体")
    Assert.eq(b.authors, "刘慈欣")
    Assert.eq(b.intro, "科幻小说")
    Assert.eq(b.category, "科幻")
    Assert.eq(b.percent, 42)
end

do -- 缺字段兜底：只有 stable_id 的行
    local list = Mapper.list({ { stable_id = "a.txt" } })
    local b = list.data[1]
    Assert.eq(b.stable_id, "a.txt")
    Assert.is_nil(b.title)
    Assert.is_nil(b.authors)
    Assert.is_nil(b.intro)
    Assert.is_nil(b.category)
    Assert.eq(b.percent, 0)
end

do -- percent 为字符串时按 tonumber 转换；非法值归零
    local list = Mapper.list({
        { stable_id = "a", percent = "37" },
        { stable_id = "b", percent = "not-a-number" },
    })
    Assert.eq(list.data[1].percent, 37)
    Assert.eq(list.data[2].percent, 0)
end

do -- 非法行被过滤：无 stable_id / 空 stable_id / 非表
    local list = Mapper.list({
        { title = "无身份" },
        { stable_id = "" },
        "不是表",
        { stable_id = "ok" },
    })
    Assert.eq(#list.data, 1)
    Assert.eq(list.data[1].stable_id, "ok")
end

do -- count 参数：显式传入优先，否则取 books 数量；rows 为 nil 时为空列表
    local with_count = Mapper.list({ { stable_id = "a" } }, 99)
    Assert.eq(with_count.count, 99)
    Assert.eq(#with_count.data, 1)

    local derived = Mapper.list({ { stable_id = "a" }, { stable_id = "b" } })
    Assert.eq(derived.count, 2)

    local empty = Mapper.list(nil)
    Assert.eq(empty.count, 0)
    Assert.eq(#empty.data, 0)
end

do -- recent 与 list 同构（无显式 count）
    local r = Mapper.recent({
        { stable_id = "x", title = "最近读" },
        { stable_id = "y" },
    })
    Assert.eq(r.count, 2)
    Assert.eq(r.data[1].source_id, "local")
    Assert.eq(r.data[1].title, "最近读")
end

-- ===== insight：formatDuration 各量级（经输出文案间接覆盖） =====

do -- 0 / 负值 / nil → 「0分钟」，has_data = false
    local r = Mapper.insight({ total_seconds = 0 }, {}, {})
    Assert.is_false(r.has_data)
    Assert.is_false(r.total.has_data)
    Assert.eq(r.total.total_text, "0分钟")

    local neg = Mapper.insight({ total_seconds = -5 }, {}, {})
    Assert.is_false(neg.has_data)
    Assert.eq(neg.total.total_text, "0分钟")

    local nil_summary = Mapper.insight(nil, nil, nil)
    Assert.is_false(nil_summary.has_data)
    Assert.eq(nil_summary.total.total_text, "0分钟")
    Assert.eq(nil_summary.total.last7_text, "0分钟")
    Assert.eq(nil_summary.total.longest_day_text, "0分钟")
end

do -- 秒级（不足 1 分钟）按最少 1 分钟显示；正数即有数据
    local r = Mapper.insight({ total_seconds = 59 }, {}, {})
    Assert.is_true(r.has_data)
    Assert.is_true(r.total.has_data)
    Assert.eq(r.total.total_text, "1分钟")
end

do -- 分钟级 / 小时级
    local m = Mapper.insight({ total_seconds = 300 }, {}, {})
    Assert.eq(m.total.total_text, "5分钟")

    local h = Mapper.insight({
        total_seconds = 3600,
        last7_seconds = 90,
        longest_day_seconds = 7265,
    }, {}, {})
    Assert.eq(h.total.total_text, "1小时0分钟")
    Assert.eq(h.total.last7_text, "1分钟")
    Assert.eq(h.total.longest_day_text, "2小时1分钟") -- 7265s = 2h65s
end

-- ===== insight：统计卡片结构组装 =====

do -- summary / daily / daily_books → 卡片结构
    FakeBooks["local\n/books/三体.epub"] = { title = "三体", authors = "刘慈欣" }
    local r = Mapper.insight(
        { total_seconds = 7265, total_pages = 123, last7_seconds = 60, longest_day_seconds = 3600 },
        {
            { ymd = "2026-08-14", seconds = 3600 },
            { ymd = "2026-08-15", seconds = 120 },
            { ymd = 20260816, seconds = 5 }, -- 非字符串 ymd 被丢弃
        },
        {
            { ymd = "2026-08-14", stable_id = "/books/三体.epub", max_page = 30, max_total_pages = 100 },
            { ymd = "2026-08-15", stable_id = "/books/未知.txt", max_page = 150, max_total_pages = 100 },
            { ymd = "2026-08-99", stable_id = "ghost", max_page = 1, max_total_pages = 10 }, -- 日期不在 daily 里
            { ymd = "2026-08-14", stable_id = "", max_page = 1, max_total_pages = 10 }, -- 空 stable_id
        }
    )
    Assert.is_true(r.has_data)
    Assert.eq(r.total.total_pages, 123)
    Assert.eq(r.total.total_text, "2小时1分钟") -- 7265s = 2h65s
    Assert.eq(r.total.last7_text, "1分钟")
    Assert.eq(r.total.longest_day_text, "1小时0分钟")
    Assert.matches(r.calendar.initial_ym, "^%d%d%d%d%-%d%d$")

    local d14 = r.calendar.days["2026-08-14"]
    Assert.eq(d14.duration_seconds, 3600)
    Assert.eq(d14.duration_text, "1小时0分钟")
    Assert.eq(#d14.books, 1) -- ghost / 空 stable_id 都不进
    Assert.eq(d14.books[1].stable_id, "/books/三体.epub")
    Assert.eq(d14.books[1].title, "三体") -- 命中 books 表缓存
    Assert.eq(d14.books[1].authors, "刘慈欣")
    Assert.eq(d14.books[1].percent, 30) -- floor(30*100/100 + 0.5)

    local d15 = r.calendar.days["2026-08-15"]
    Assert.eq(d15.duration_text, "2分钟")
    Assert.eq(#d15.books, 1)
    Assert.eq(d15.books[1].title, "未知") -- 无缓存时取文件名去扩展名
    Assert.is_nil(d15.books[1].authors)
    Assert.eq(d15.books[1].percent, 100) -- 超 100 钳制

    Assert.is_nil(r.calendar.days["20260816"])
end

do -- max_total_pages 为 0 / nil 时 percent 为 0；无 daily 时 days 为空
    local r = Mapper.insight(
        { total_seconds = 10 },
        { { ymd = "2026-08-15", seconds = 10 } },
        {
            { ymd = "2026-08-15", stable_id = "a", max_page = 5, max_total_pages = 0 },
            { ymd = "2026-08-15", stable_id = "b", max_page = 5 }, -- max_total_pages 缺失
        }
    )
    local books = r.calendar.days["2026-08-15"].books
    Assert.eq(#books, 2)
    Assert.eq(books[1].percent, 0)
    Assert.eq(books[2].percent, 0)

    local no_daily = Mapper.insight({ total_seconds = 10 }, nil, nil)
    Assert.is_nil(next(no_daily.calendar.days))
end

-- 收尾：不影响同进程内后续用例
package.preload["utils.db.book"] = nil
package.loaded["utils.db.book"] = nil
package.loaded["source.local.mapper"] = nil
