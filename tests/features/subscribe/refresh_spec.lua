--[[-- features.subscribe.refresh：订阅刷新走后台任务队列；全局只有一轮，再要刷的源并进队尾；逐个串行；通知监听者。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local enqueued, followed = {}, 0
package.loaded["workers.tasks"] = {
    get = function(key) for i = #enqueued, 1, -1 do if enqueued[i].key == key then return enqueued[i] end end end,
    enqueue = function(spec)
        enqueued[#enqueued + 1] = spec
        spec.state = "running"
        spec.handle = spec.run(function(text, n, total) spec.text, spec.count, spec.total = text, n, total end,
            function(result) spec.state, spec.done, spec.result = "finished", true, result end)
        return spec
    end,
}
package.loaded["workers.ui.task_dialog"] = { follow = function() followed = followed + 1 end }
package.loaded["ui.themes.widgets.toast"] = { new = function(_self, o) return { show = function() _G.__toast = o.text end } end }

local pending, calls = {}, {}
package.loaded["features.subscribe"] = {
    refresh = function(feed, more, cb)
        calls[#calls + 1] = feed.id .. (more and "+" or "")
        pending[#pending + 1] = cb
        return { cancel = function() end }
    end,
}
package.loaded["features.subscribe.refresh"] = nil
local Refresh = require("features.subscribe.refresh")
Refresh.CONCURRENCY = 1

local events = {}
local unwatch = Refresh.watch(function(text, finished) events[#events + 1] = finished and "done" or text end)

-- 起一轮：进任务队列（kind = sync），手动刷新弹前台进度窗
Assert.is_true(Refresh.start({ { id = 1, title = "A" }, { id = 2, title = "B" } }, { follow = true }))
Assert.len(enqueued, 1)
Assert.eq(enqueued[1].kind, "sync")
Assert.eq(followed, 1)
Assert.eq(table.concat(calls, ","), "1", "串行：一次只拉一个源")
Assert.eq(Refresh.status(), "正在刷新 A…")
Assert.not_nil(Refresh.status())

-- 在跑时再要刷新：并进本轮（重复的源不再排），不另起任务
Assert.is_false(Refresh.start({ { id = 2, title = "B" }, { id = 3, title = "C" } }))
Assert.len(enqueued, 1, "不并发")
-- 翻更早一页在刷新时也排队（插队到队首），不能静默丢掉点击
Assert.is_false(Refresh.start({ { id = 1, title = "A" } }, { more = true }))

pending[1](2); Stubs.flush()
Assert.eq(table.concat(calls, ","), "1,1+", "更早一页紧跟其后")
pending[2](1); Stubs.flush()
Assert.eq(table.concat(calls, ","), "1,1+,2")
pending[3](nil, "HTTP 500"); Stubs.flush()
pending[4](0); Stubs.flush()
Assert.eq(table.concat(calls, ","), "1,1+,2,3")
Assert.is_true(enqueued[1].done)
Assert.is_false(enqueued[1].result.ok)
Assert.matches(enqueued[1].result.err, "B: HTTP 500")
Assert.is_nil(Refresh.status())
Assert.eq(events[#events], "done", "刷完通知订阅页重画")
Assert.eq(enqueued[1].total, 4)

-- 网页单个刷新：per-feed 回调；跑完再起新一轮
local got
Assert.is_true(Refresh.start({ { id = 9, title = "W" } }, { on_feed = function(_f, added, err) got = { added, err } end }))
Assert.len(enqueued, 2)
pending[5](5); Stubs.flush()
Assert.eq(got[1], 5)

-- 任务在排队时被取消（run 没跑）：残留的本轮被清掉，下次能重新起
package.loaded["workers.tasks"].enqueue = function(spec) spec.state = "queued"; enqueued[#enqueued + 1] = spec; return spec end
Assert.is_true(Refresh.start({ { id = 4, title = "D" } }))
Assert.not_nil(Refresh.status())
enqueued[#enqueued].state = "cancelled"
Assert.is_nil(Refresh.status())
Assert.is_true(Refresh.start({ { id = 4, title = "D" } }))

-- 取消在跑的一轮：剩下的网页回调收到错误
package.loaded["workers.tasks"].enqueue = function(spec)
    enqueued[#enqueued + 1] = spec
    spec.state = "running"
    spec.handle = spec.run(function() end, function() end)
    return spec
end
Refresh._reset()
local errs = {}
Refresh.start({ { id = 5, title = "E" }, { id = 6, title = "F" } }, { on_feed = function(_f, _a, err) errs[#errs + 1] = err end })
enqueued[#enqueued].handle.cancel()
Assert.len(errs, 2)
Assert.is_nil(Refresh.status())
-- 单个源插队：整轮在刷时点某个源刷新，它排到下一个（队里已有的同一源挪到前面），不用等整轮刷完
Refresh._reset(); calls, pending = {}, {}
Refresh.start({ { id = 11, title = "K1" }, { id = 12, title = "K2" }, { id = 13, title = "K3" } })
local one
Assert.is_false(Refresh.start({ { id = 13, title = "K3" } }, { on_feed = function(_f, added) one = added end }))
pending[1](0); Stubs.flush()
Assert.eq(table.concat(calls, ","), "11,13", "单源插到队首")
pending[2](4); Stubs.flush()
Assert.eq(one, 4)
pending[3](0); Stubs.flush()
Assert.eq(table.concat(calls, ","), "11,13,12", "同一源不再刷第二遍")
Assert.is_nil(Refresh.status())
-- 公众号授权失效（-2041）：一轮只弹一次窗（不是每个源一次），30 分钟内不再弹
do
    local shown = {}
    package.loaded["ui.themes.widgets.confirm"] = { new = function(_self, o) return { show = function() shown[#shown + 1] = o.text end } end }
    package.loaded["source.wechat.mp"] = { AUTH_EXPIRED = "公众号授权已失效，请在微信读书 App 中打开任意公众号重新授权后再试" }
    local AUTH = package.loaded["source.wechat.mp"].AUTH_EXPIRED
    Refresh._reset(); calls, pending = {}, {}
    Refresh.start({ { id = 21, title = "M1" }, { id = 22, title = "M2" } })
    pending[1](nil, AUTH); Stubs.flush()
    Assert.len(shown, 0, "整轮结束才弹")
    pending[2](nil, AUTH); Stubs.flush()
    Assert.len(shown, 1, "一轮只弹一次")
    Assert.eq(shown[1], AUTH)
    Refresh.start({ { id = 21, title = "M1" } })
    pending[3](nil, AUTH); Stubs.flush()
    Assert.len(shown, 1, "30 分钟内不再弹")
    Refresh.start({ { id = 23, title = "R" } })
    pending[4](nil, "HTTP 500"); Stubs.flush()
    Assert.len(shown, 1, "别的错误不弹")
end
-- 并发：同时在飞 CONCURRENCY 个，一个回来补一个，全部回来才算结束
do
    Refresh.CONCURRENCY = 2
    Refresh._reset(); calls, pending = {}, {}
    Refresh.start({ { id = 31, title = "P1" }, { id = 32, title = "P2" }, { id = 33, title = "P3" } })
    Assert.eq(table.concat(calls, ","), "31,32", "同时在飞 2 个")
    pending[2](1); Stubs.flush()
    Assert.eq(table.concat(calls, ","), "31,32,33", "回来一个补一个")
    pending[1](0); Stubs.flush()
    Assert.not_nil(Refresh.status(), "还有一个在飞")
    pending[3](0); Stubs.flush()
    Assert.is_nil(Refresh.status())
    Refresh.CONCURRENCY = 1
end
-- 自动刷新（quiet）失败不弹 toast；非 quiet 的后台刷新失败照常弹。
do
    -- 上面取消用例把 enqueue 桩换成了 finish 不记 result 的版本，这里换回记 result 的。
    package.loaded["workers.tasks"].enqueue = function(spec)
        enqueued[#enqueued + 1] = spec
        spec.state = "running"
        spec.handle = spec.run(function() end,
            function(result) spec.state, spec.done, spec.result = "finished", true, result end)
        return spec
    end
    Refresh._reset(); calls, pending = {}, {}
    _G.__toast = nil
    Refresh.start({ { id = 41, title = "Q" } }, { quiet = true })
    pending[#pending](nil, "HTTP 500"); Stubs.flush()
    local spec = enqueued[#enqueued]
    spec.on_done(spec.result)
    Assert.is_nil(_G.__toast, "自动刷新失败不弹 toast")
    Refresh._reset()
    Refresh.start({ { id = 42, title = "M" } })
    pending[#pending](nil, "HTTP 500"); Stubs.flush()
    spec = enqueued[#enqueued]
    spec.on_done(spec.result)
    Assert.matches(_G.__toast, "M: HTTP 500", "手动后台刷新失败弹 toast")
    _G.__toast = nil
end
unwatch()
