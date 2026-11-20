--[[-- features.reviews.sheet：关闭 / 切换 / 迟到回调不得再 refresh 或 close 新面板。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
require("support.modal_stub").install()
package.preload["l10n"] = function() return { apply = function() end } end
for _idx, name in ipairs({ "ui.themes", "ui.themes.widgets.box", "ui.themes.widgets.icon", "ui.themes.widgets.image",
        "ui.themes.widgets.pager", "ui.themes.widgets.text", "ui.themes.widgets.titlebar",
        "ui/gesturerange", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/verticalgroup" }) do
    package.preload[name] = function() return {} end
end

local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return {
        new = function(_self, opts)
            return {
                show = function()
                    toasts[#toasts + 1] = opts.text
                end,
            }
        end,
    }
end

local Sheet = require("features.reviews.sheet")

local function bind_lifecycle(fake)
    fake.closed = false
    fake.generation = fake.generation or 1
    fake.refresh_count = 0
    fake.close_count = 0
    fake.cancelled = 0
    function fake:refresh()
        if self.closed then
            self.refresh_after_close = (self.refresh_after_close or 0) + 1
            return
        end
        self.refresh_count = self.refresh_count + 1
    end
    function fake:close()
        self.close_count = self.close_count + 1
        if self.close_callback then self.close_callback() end
    end
    fake.close_callback = function()
        fake.closed = true
        fake.generation = (fake.generation or 0) + 1
        if fake.job then fake.job.cancel() end
        fake.job = nil
    end
    return fake
end

local function sheet(source_opts)
    local fake = setmetatable({
        identity = { source = source_opts },
        spot = source_opts.spot or { range = "r1", text = "原句", total = 3 },
        reply_page = source_opts.reply_page,
        more = true,
        max_idx = 0,
        items = {},
        page = 1,
        loaded = false,
        paginate = function(self) self.pages = { { 1, math.max(0, #self.items) } } end,
    }, { __index = Sheet })
    return bind_lifecycle(fake)
end

-- 成功迟到：关闭后不 refresh、不改 items。
do
    local cb, cancelled = nil, 0
    local fake = sheet({
        paragraphReviewPageAsync = function(_self, _identity, _range, _max_idx, callback)
            cb = callback
            return { cancel = function() cancelled = cancelled + 1 end }
        end,
    })
    fake:load()
    Assert.not_nil(cb)
    fake:close()
    Assert.eq(cancelled, 1)
    Assert.is_true(fake.closed)
    cb({ items = { { id = "late" } }, total = 1, max_idx = 1, more = false })
    Assert.len(fake.items, 0, "关闭后成功回调不得追加评论")
    Assert.eq(fake.refresh_count, 0)
    Assert.is_nil(fake.refresh_after_close)
    Assert.eq(fake.close_count, 1)
end

-- 失败迟到：关闭后不 toast、不 close 新面板。
do
    toasts = {}
    local cb
    local fake = sheet({
        paragraphReviewPageAsync = function(_self, _identity, _range, _max_idx, callback)
            cb = callback
            return { cancel = function() end }
        end,
    })
    local newer = sheet({
        paragraphReviewPageAsync = function() return { cancel = function() end } end,
    })
    newer.close = function(self)
        self.close_count = (self.close_count or 0) + 1
    end
    fake:load()
    fake:close()
    cb(nil, "boom")
    Assert.len(toasts, 0, "关闭后失败不得弹 Toast")
    Assert.eq(fake.close_count, 1)
    Assert.eq(newer.close_count or 0, 0, "过期失败不得关闭另一张面板")
end

-- 看回复后关闭：不走 ReviewCache 的迟到回调同样作废。
do
    local cb, cancelled = nil, 0
    local fake = sheet({
        reply_page = true,
        paragraphReviewRepliesAsync = function(_self, _identity, review_id, max_idx, callback)
            Assert.eq(review_id, "r1")
            Assert.eq(max_idx, 0)
            cb = callback
            return { cancel = function() cancelled = cancelled + 1 end }
        end,
    })
    fake.reply_page = true
    fake:load()
    fake:close()
    Assert.eq(cancelled, 1)
    cb({ items = { { id = "c" } }, total = 4, max_idx = 2, more = false })
    Assert.len(fake.items, 0)
    Assert.eq(fake.refresh_count, 0)
end

-- 同步成功：当场刷新；同一请求不会重入再拉。
do
    local calls = 0
    local fake = sheet({
        paragraphReviewPageAsync = function(_self, _identity, _range, _max_idx, callback)
            calls = calls + 1
            callback({ items = { { id = "s" } }, total = 1, max_idx = 1, more = false })
            return { cancel = function() end }
        end,
    })
    fake:load()
    Assert.eq(calls, 1)
    Assert.eq(fake.refresh_count, 1)
    Assert.len(fake.items, 1)
    Assert.is_false(fake.more)
    Assert.is_nil(fake.job, "同步返回不留下在飞任务")
    fake:load()
    Assert.eq(calls, 1, "没有 more 时不得重入再请求")
end

-- 同步失败：未加载则 close；关闭后同一回调栈里也不会再 refresh。
do
    toasts = {}
    local fake = sheet({
        paragraphReviewPageAsync = function(_self, _identity, _range, _max_idx, callback)
            callback(nil, "offline")
            return { cancel = function() end }
        end,
    })
    fake:load()
    Assert.len(toasts, 1)
    Assert.eq(fake.close_count, 1)
    Assert.is_true(fake.closed)
    Assert.eq(fake.refresh_count, 0)
    Assert.is_nil(fake.job)
end

-- 同步回调里关窗：函数返回后不得再挂上 job，也不 refresh。
do
    local cancelled, cb_job = 0, nil
    local fake
    fake = sheet({
        paragraphReviewPageAsync = function(_self, _identity, _range, _max_idx, callback)
            cb_job = { cancel = function() cancelled = cancelled + 1 end }
            fake:close()
            callback({ items = { { id = "too-late" } }, total = 1, max_idx = 1, more = false })
            return cb_job
        end,
    })
    fake:load()
    Assert.len(fake.items, 0)
    Assert.eq(fake.refresh_count, 0)
    Assert.is_nil(fake.job)
    -- 发起方在同步 close 之后才返回句柄：load 应主动 cancel，避免任务继续跑。
    Assert.eq(cancelled, 1)
end

-- 在飞时重入 load 不会开第二个请求。
do
    local calls = 0
    local fake = sheet({
        paragraphReviewPageAsync = function(_self, _identity, _range, _max_idx, callback)
            calls = calls + 1
            return { cancel = function() end }
        end,
    })
    fake:load()
    fake:load()
    Assert.eq(calls, 1, "已有 job 时不得重入")
end

-- 已关闭再 load 直接返回。
do
    local calls = 0
    local fake = sheet({
        paragraphReviewPageAsync = function()
            calls = calls + 1
            return { cancel = function() end }
        end,
    })
    fake:close()
    fake:load()
    Assert.eq(calls, 0)
end
