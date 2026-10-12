--[[--
拷贝漫画离线打开：已有 CBZ（按章节 uuid 命名）时不触发目录/详情/下载；
起始章取显式章号或本地进度；没缓存又没网立即失败。

@module tests.source.copymanga.open_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local calls = 0
local touched
local pending
local connected = false

local function stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = nil
end

stub("gettext", function()
    return function(value) return value end
end)
stub("source.base", function()
    return {
        defer = function(cb, ...)
            local args = { n = select("#", ...), ... }
            require("ui/uimanager"):nextTick(function() cb(unpack(args, 1, args.n)) end)
            return { cancel = function() end }
        end,
    }
end)
stub("source.shelf", function() return {} end)
stub("source.toc", function()
    return {
        -- 目录过期也照用：离线开书要靠它把章号换成 uuid。
        read = function() return nil end,
    }
end)
stub("source.copymanga.mapper", function() return {} end)
stub("utils.settings", function()
    return { getSource = function() return {} end }
end)
stub("source.copymanga.client", function()
    return {
        new = function()
            return setmetatable({}, {
                __index = function()
                    return function()
                        calls = calls + 1
                        error("network path reached")
                    end
                end,
            })
        end,
        headers = function() return {} end,
    }
end)
stub("ffi/archiver", function() return { Writer = { new = function() return {} end } } end)
stub("utils.paths", function()
    return {
        bookWorkDir = function() return "/offline-cache/comic" end,
    }
end)
stub("libs/libkoreader-lfs", function()
    return {
        attributes = function(path)
            if path == "/offline-cache/comic/uuid-2.cbz" then
                return { mode = "file", size = 42 }
            end
            return nil
        end,
    }
end)
stub("json", function()
    return { decode = require("support.json_stub").decode }
end)
stub("book.books_db", function()
    return {
        getToc = function(_, _, max_age)
            Assert.is_nil(max_age, "离线开书读目录不看 TTL")
            return '[{"idx":1,"uid":"uuid-1"},{"idx":2,"uid":"uuid-2"},{"idx":3,"uid":"uuid-3"}]'
        end,
    }
end)
stub("book.progress_db", function()
    return { get = function() return pending end }
end)
stub("ui/network/manager", function()
    return { isConnected = function() return connected end }
end)
stub("book.store", function()
    return {
        touch = function(path, identity, opts)
            touched = { path = path, identity = identity, opts = opts }
            return true
        end,
    }
end)

package.loaded["source.copymanga.chapter"] = nil
package.loaded["source.copymanga"] = nil
local Copymanga = require("source.copymanga")
local source = Copymanga.new()
local identity = {
    source_id = "copymanga",
    stable_id = "comic",
    book = {},
}

local function open(opts)
    local result, err
    source:openBookAsync(identity, opts, function(path, open_err)
        result, err = path, open_err
    end)
    Stubs.flush()
    return result, err
end

-- 显式章号：按目录换成 uuid，命中已下载的 CBZ。
do
    touched = nil
    local result, err = open({ chapter_idx = 2 })
    Assert.eq(calls, 0)
    Assert.eq(result, "/offline-cache/comic/uuid-2.cbz")
    Assert.is_nil(err)
    Assert.eq(touched.path, result)
    Assert.eq(touched.opts.chapter_idx, 2)
end

-- 不带章号：用本地进度的章号。
do
    pending = { chapter_idx = 2, fraction = 0.1 }
    local result = open(nil)
    Assert.eq(result, "/offline-cache/comic/uuid-2.cbz")
    pending = nil
end

-- 本地进度没有章号：按全书比例换算（2/3 → 第 3 章，没下载）；离线立即失败，不发请求。
do
    pending = { fraction = 0.7 }
    touched = nil
    local result, err = open(nil)
    Assert.is_nil(result)
    Assert.eq(err, "网络不可用，请先连接 Wi-Fi")
    Assert.is_nil(touched)
    Assert.eq(calls, 0)
    pending = nil
end
