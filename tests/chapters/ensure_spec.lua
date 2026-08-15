--[[--
chapters ensure / prefetch 离线用例

@module tests.chapters.ensure_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Fakes = require("support.chapter_fakes")
Stubs.install()
Stubs.reset()

local files = {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            local body = files[path]
            if not body then
                return nil
            end
            return { mode = "file", size = #body }
        end,
        mkdir = function() return true end,
        dir = function() return function() end end,
    }
end

Fakes.install()

local real_open = io.open
io.open = function(path, mode)
    mode = mode or "r"
    if mode:find("w") then
        local buf = {}
        return {
            write = function(_, data) buf[#buf + 1] = data end,
            close = function()
                files[path] = table.concat(buf)
            end,
        }
    end
    if files[path] then
        local data = files[path]
        local pos = 1
        return {
            read = function(_, n)
                if n == "*a" then
                    local out = data:sub(pos)
                    pos = #data + 1
                    return out
                end
                local out = data:sub(pos, pos + (tonumber(n) or 1) - 1)
                pos = pos + #out
                return out ~= "" and out or nil
            end,
            close = function() end,
            seek = function() end,
        }
    end
    return real_open(path, mode)
end

local old_rename = os.rename
local old_remove = os.remove
os.rename = function(a, b)
    if files[a] then
        files[b] = files[a]
        files[a] = nil
        return true
    end
    return old_rename(a, b)
end
os.remove = function(path)
    files[path] = nil
    return true
end

for _, name in ipairs({
    "chapters.html", "chapters.session", "chapters.materialize",
    "chapters.navigate", "chapters", "chapters.init",
    "book.store", "libs/libkoreader-lfs",
}) do
    package.loaded[name] = nil
end

local Chapters = require("chapters")
local UIManager = require("ui/uimanager")
local fetch_calls = 0
local source = {
    fetchChapterContentAsync = function(_, _ref, chapter, cb)
        fetch_calls = fetch_calls + 1
        UIManager:nextTick(function()
            cb({ title = chapter.title or "t", html = "<p>body " .. tostring(chapter.idx) .. "</p>" })
        end)
    end,
}
local ref = { book_key = "bk", source_id = "wechat", stable_id = "s1" }
local toc = {
    { idx = 1, title = "一" },
    { idx = 2, title = "二" },
    { idx = 3, title = "三" },
    { idx = 4, title = "四" },
    { idx = 5, title = "五" },
}

do
    fetch_calls = 0
    local results = {}
    Chapters.ensureAsync(source, ref, 1, toc, function(ok, path)
        results[#results + 1] = { ok, path }
    end)
    Chapters.ensureAsync(source, ref, 1, toc, function(ok, path)
        results[#results + 1] = { ok, path }
    end)
    Stubs.flush()
    Assert.eq(fetch_calls, 1)
    Assert.eq(#results, 2)
    Assert.is_true(results[1][1])
    Assert.eq(results[1][2], results[2][2])
end

do
    local before = fetch_calls
    local ok_hit
    Chapters.ensureAsync(source, ref, 1, toc, function(ok)
        ok_hit = ok
    end)
    Stubs.flush()
    Assert.eq(ok_hit, true)
    Assert.eq(fetch_calls, before)
end

Chapters.bind({
    plugin = { emitToSource = function() end },
    source = source,
    book = {},
    ref = ref,
    toc = toc,
    idx = 1,
})
fetch_calls = 0
for i = 2, 4 do
    files["/tmp/moon-ch-bk-" .. i .. ".html"] = nil
end
Chapters.prefetchAround(1)
Stubs.flush()
Assert.eq(fetch_calls, 3)

Chapters.clear()
io.open = real_open
os.rename = old_rename
os.remove = old_remove
