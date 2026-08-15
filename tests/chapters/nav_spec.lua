--[[--
chapters 导航 / EndOfBook 离线用例

@module tests.chapters.nav_spec
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
            if body then
                return { mode = "file", size = #body }
            end
            return nil
        end,
        mkdir = function() return true end,
    }
end

local touches = {}
local switched = {}
Fakes.install({
    switched = switched,
    store_impl = {
        chapterPath = function(book_key, idx)
            return "/tmp/moon-nav-" .. book_key .. "-" .. idx .. ".html"
        end,
        touchAsync = function(path, ref, opts)
            touches[#touches + 1] = { path = path, idx = opts and opts.chapter_idx }
        end,
        getToc = function() return nil end,
        putTocAsync = function() end,
    },
})

local real_open = io.open
io.open = function(path, mode)
    mode = mode or "r"
    if mode:find("w") then
        local buf = {}
        return {
            write = function(_, d) buf[#buf + 1] = d end,
            close = function() files[path] = table.concat(buf) end,
        }
    end
    if files[path] then
        local data = files[path]
        local pos = 1
        return {
            read = function(_, n)
                if n == "*a" then
                    return data
                end
                local out = data:sub(pos, pos + (n or 1) - 1)
                pos = pos + #out
                return out ~= "" and out or nil
            end,
            close = function() end,
        }
    end
    return nil
end
os.rename = function(a, b)
    if files[a] then
        files[b] = files[a]
        files[a] = nil
        return true
    end
    return false
end
os.remove = function(p) files[p] = nil; return true end

for _, name in ipairs({
    "chapters.html", "chapters.session", "chapters.materialize",
    "chapters.navigate", "chapters", "chapters.init",
    "book.store", "apps/reader/readerui", "libs/libkoreader-lfs",
}) do
    package.loaded[name] = nil
end

local toc = {
    { idx = 1, title = "一" },
    { idx = 2, title = "二" },
    { idx = 3, title = "三" },
}
local ref = { book_key = "bk", source_id = "wechat", stable_id = "s" }

for i = 1, 3 do
    local p = "/tmp/moon-nav-bk-" .. i .. ".html"
    files[p] = "<!DOCTYPE html><html><body><p>c" .. i .. "</p></body></html>"
end

package.preload["book.store"] = function()
    return {
        chapterPath = function(stable_id, idx)
            return "/tmp/moon-nav-bk-" .. idx .. ".html"
        end,
        getToc = function() return nil end,
        putTocAsync = function() end,
        remember = function() end,
        touchAsync = function() end,
    }
end

package.preload["chapters.html"] = function()
    return {
        isValid = function(path)
            return files[path] ~= nil
        end,
    }
end

local Chapters = require("chapters")

Chapters.bind({
    plugin = { emitToSource = function() end },
    source = {},
    book = {},
    ref = ref,
    toc = toc,
    idx = 1,
})

Assert.is_true(Chapters.onEndOfBook())
Stubs.flush()
Assert.eq(Chapters.currentIdx(), 2)
Assert.is_true(#switched >= 1)
Assert.is_true(Chapters.isActive())

Assert.is_false(Chapters.onCloseDocument("/tmp/moon-nav-bk-1.html"))
Assert.is_true(Chapters.isActive())
Assert.eq(Chapters.currentIdx(), 2)

Assert.is_true(Chapters.onStartOfBook())
Stubs.flush()
Assert.eq(Chapters.currentIdx(), 1)

Assert.is_false(Chapters.onStartOfBook())

Chapters.gotoChapter(3, { within = 0.4 })
local s = require("chapters.session").get()
Assert.eq(s.pending_within, 0.4)

Chapters.clear()
io.open = real_open
