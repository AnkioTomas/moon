--[[--
共用 CBZ 打包器走 cbz_fit：按序写出切片页；番茄 / 快看 / 拷贝 / 知音漫客都经此入口。

@module tests.source.cbz_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local added = {}
package.loaded["ffi/archiver"] = {
    Writer = {
        new = function()
            return {
                open = function() return true end,
                setZipCompression = function() return true end,
                addFileFromMemory = function(_self, name, data)
                    added[#added + 1] = { name = name, data = data }
                    return true
                end,
                close = function() end,
            }
        end,
    },
}

local ticks = {}
package.loaded["ui/uimanager"] = {
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
}
package.loaded["ui.guard"] = {
    wrap = function(_name, fn) return fn end,
}

local Cbz = require("source.cbz")
local Fit = require("source.cbz_fit")

local function drain()
    while #ticks > 0 do
        local fn = table.remove(ticks, 1)
        fn()
    end
end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-cbz-spec"
os.execute("mkdir -p '" .. dir .. "'")

local function writeFile(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

do -- 宽图缩小、高图切片后按序成为独立页
    added, ticks = {}, {}
    local src1 = dir .. "/page_a.jpg"
    local src2 = dir .. "/page_b.jpg"
    writeFile(src1, "wide")
    writeFile(src2, "tall")
    Fit.backend = {
        materialize = function(path, dest, start, screen_w, _screen_h)
            Assert.eq(screen_w, 1072)
            os.execute("mkdir -p '" .. dest .. "'")
            if path == src1 then
                return { { path = path, name = Fit.pageName(start, ".jpg"), temp = false } }
            end
            local pages = {}
            for i = 1, 3 do
                local name = Fit.pageName(start + i - 1, ".jpg")
                local out = dest .. "/" .. name
                writeFile(out, "slice-" .. i)
                pages[i] = { path = out, name = name, temp = true }
            end
            return pages
        end,
    }
    local archive = dir .. "/chapter.cbz"
    writeFile(archive .. ".part", "stale")
    -- 让 rename 成功：先让 .part 在 build 开头被删掉，结束时 writer 不真正写文件，
    -- 所以这里把目标路径预先写成空，改用 os.rename 可用的假 .part。
    local old_rename = os.rename
    local renamed = {}
    os.rename = function(from, to)
        renamed[#renamed + 1] = { from, to }
        if from:sub(-5) == ".part" then
            writeFile(to, "cbz")
            os.remove(from)
            return true
        end
        return old_rename(from, to)
    end
    package.loaded["device"] = {
        screen = {
            getWidth = function() return 1072 end,
            getHeight = function() return 1448 end,
        },
    }
    local result, err
    Cbz.build({ src1, src2 }, archive, { cancelled = false }, function(path, reason)
        result, err = path, reason
    end)
    drain()
    os.rename = old_rename
    Fit.backend = nil
    Assert.is_nil(err)
    Assert.eq(result, archive)
    Assert.len(added, 4)
    Assert.eq(added[1].name, "0001.jpg")
    Assert.eq(added[2].name, "0002.jpg")
    Assert.eq(added[3].name, "0003.jpg")
    Assert.eq(added[4].name, "0004.jpg")
    Assert.eq(added[2].data, "slice-1")
    Assert.eq(added[4].data, "slice-3")
    -- 源图在打包成功后删除；切片临时文件也应清掉。
    Assert.is_nil(io.open(src1, "rb"))
    Assert.is_nil(io.open(src2, "rb"))
end

do -- 所有漫画源都走共用打包器
    local files = {
        "book.koplugin/source/fanqie/comic.lua",
        "book.koplugin/source/kuaikan/chapter.lua",
        "book.koplugin/source/copymanga/chapter.lua",
        "book.koplugin/source/zymk/chapter.lua",
    }
    for _idx, rel in ipairs(files) do
        local file = assert(io.open(rel, "r"))
        local src = file:read("*a")
        file:close()
        Assert.is_true(src:find('require%("source%.cbz"%)', 1) ~= nil, rel)
        Assert.is_true(src:find("Cbz%.build", 1) ~= nil, rel)
        Assert.is_nil(src:find("cbz_fit", 1, true), rel)
    end
end

do -- 非漫画路径打开前不拦截
    local called
    local handle = Cbz.ensureAsync("/library/book.epub", function(path, err)
        called = { path, err }
    end)
    Assert.eq(called[1], "/library/book.epub")
    Assert.is_nil(called[2])
    handle.cancel()
end

do -- 过大的已缓存 CBZ 打开前会重打包
    local rebuilt = {}
    local orig_rebuild = Cbz.rebuild
    local orig_ready = Cbz.ready
    local orig_needs = Cbz.needsFit
    Cbz.ready = function() return true end
    Cbz.needsFit = function(path)
        Assert.eq(path, "/cache/fanqie/767.cbz")
        return true, 2
    end
    Cbz.rebuild = function(path, _state, cb)
        rebuilt[#rebuilt + 1] = path
        cb(path, nil, { old_pages = 2, new_pages = 5 })
    end
    local started = false
    local result
    Cbz.ensureAsync("/cache/fanqie/767.cbz", function(path)
        result = path
    end, { on_rebuild = function() started = true end })
    Cbz.rebuild = orig_rebuild
    Cbz.ready = orig_ready
    Cbz.needsFit = orig_needs
    Assert.is_true(started)
    Assert.eq(rebuilt[1], "/cache/fanqie/767.cbz")
    Assert.eq(result, "/cache/fanqie/767.cbz")
end

os.execute("rm -rf '" .. dir .. "'")
return true
