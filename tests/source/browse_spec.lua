--[[--
书城浏览公共分页：凑够 limit 停、空页 / 无更多停、出错透传、取消转给在飞请求。

@module tests.source.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Browse = require("source.browse")

local function fetcher(pages, calls)
    return function(page, done)
        calls[#calls + 1] = page
        local rows = pages[page]
        if rows then done(rows, nil, rows.more) else done({}) end
        return { cancel = function() calls.cancelled = true end }
    end
end

do
    local calls, out = {}, nil
    local group = { chips = { { id = "g", title = "组" } }, active = "g" }
    Browse.pages(fetcher({ { "a", "b" }, { "c", "d" }, { "e" } }, calls), 3, { group }, function(res) out = res end)
    Assert.len(out.data, 4)
    Assert.len(calls, 2)
    Assert.eq(out.groups[1], group)
end

do
    local calls, out = {}, nil
    Browse.pages(fetcher({ { "a", more = false }, { "b" } }, calls), 60, {}, function(res) out = res end)
    Assert.len(out.data, 1)
    Assert.len(calls, 1)
end

do
    local calls, out = {}, nil
    Browse.pages(fetcher({ { "a" } }, calls), 60, {}, function(res) out = res end)
    Assert.len(out.data, 1)
    Assert.len(calls, 2)
end

do
    local err
    Browse.pages(function(_page, done) done(nil, "boom") end, 60, {}, function(res, e) err = e; Assert.is_nil(res) end)
    Assert.eq(err, "boom")
end

do
    local calls = {}
    local handle = Browse.pages(function(_page, _done) calls.cancelled = false; return { cancel = function() calls.cancelled = true end } end,
        60, {}, function() end)
    handle.cancel()
    Assert.is_true(calls.cancelled)
end

do
    local g = Browse.group({ { id = "x", title = "X" }, { id = "y", title = "Y" } }, "y")
    Assert.eq(g.active, "y")
    Assert.is_nil(Browse.group({ { id = "x", title = "X" } }, "z").active)
end

do
    local late, cancelled, completed
    local handle = Browse.pages(function(page, done)
        if page == 1 then
            done({ { source_id = "test", stable_id = "one" } }, nil, true)
            return { cancel = function() error("cancelled completed first request") end }
        end
        late = done
        return { cancel = function() cancelled = true end }
    end, 60, {}, function() completed = true end)
    handle.cancel()
    Assert.is_true(cancelled)
    late({ { source_id = "test", stable_id = "two" } }, nil, false)
    Assert.is_nil(completed)
end

do
    local calls, err = 0, nil
    Browse.pages(function(_page, done)
        calls = calls + 1
        done({ { source_id = "test", stable_id = "same" } }, nil, true)
    end, 60, {}, function(res, reason) Assert.is_nil(res); err = reason end)
    Assert.eq(calls, 2)
    Assert.eq(err, "响应无效")
end
