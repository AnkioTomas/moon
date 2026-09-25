--[[-- dictionary.manager：资源清单校验。 --]]

local Assert = require("support.assert")

package.preload["json"] = function() return {} end
local download_call
package.preload["http.request"] = function()
    return {
        download = function(opts, dest, cb)
            download_call = { opts = opts, dest = dest, cb = cb }
            return { cancel = function() end }
        end,
    }
end
package.preload["utils.paths"] = function()
    return { root = function() return "/tmp" end, ensureSettings = function() end }
end
package.preload["util"] = function()
    return { makePath = function() return true end }
end

local target_mode
local part_present = true
local tmp_mode = "directory"
local lfs = {}
function lfs.attributes(path, name)
    local attr
    if path == "/tmp/dict-xhzd.dl/xhzd.part.001" and part_present then
        attr = { mode = "file", size = 5 }
    end
    return name and attr and attr[name] or attr
end
function lfs.symlinkattributes(path, name)
    local attr
    if path == "/tmp/dict-xhzd.dl" then
        attr = { mode = tmp_mode }
    elseif path == "/dict/book-xhzd" and target_mode then
        attr = { mode = target_mode }
    elseif path == "/dict/book-xhzd/external" then
        attr = { mode = "link" }
    end
    return name and attr and attr[name] or attr
end
package.preload["libs/libkoreader-lfs"] = function() return lfs end

package.preload["workers.job"] = function()
    return { run = function() end }
end

local Manager = require("dictionary.manager")
local hash = string.rep("a", 64)
local item = {
    id = "xhzd", name = "新华字典", size = 5, sha256 = hash,
    parts = { { file = "xhzd.part.001", size = 5, sha256 = hash } },
}
local items = assert(Manager.validateManifest({ dictionaries = { item } }))
Assert.len(items, 1)
Assert.eq(items[1].id, "xhzd")

local hyphen_id = {
    id = "langdao-ec", name = "朗道英汉字典", size = 5, sha256 = hash,
    parts = { { file = "langdao-ec.part.001", size = 5, sha256 = hash } },
}
Assert.not_nil(Manager.validateManifest({ dictionaries = { hyphen_id } }))

local bad_id = { id = "../bad", name = "bad", size = 5, sha256 = hash, parts = item.parts }
Assert.is_nil(Manager.validateManifest({ dictionaries = { bad_id } }))
local bad_part = {
    id = "xhzd", name = "bad", size = 5, sha256 = hash,
    parts = { { file = "../x", size = 5, sha256 = hash } },
}
Assert.is_nil(Manager.validateManifest({ dictionaries = { bad_part } }))
local bad_sum = {
    id = "xhzd", name = "bad", size = 6, sha256 = hash,
    parts = { { file = "xhzd.part.001", size = 5, sha256 = hash } },
}
Assert.is_nil(Manager.validateManifest({ dictionaries = { bad_sum } }))

local available_ifos = { "stale" }
local init_calls = 0
local dictionary = {
    init = function()
        local _ = available_ifos
        init_calls = init_calls + 1
    end,
}
Manager.refresh(dictionary)
Assert.is_false(available_ifos)
Assert.eq(init_calls, 1)

local install_result, progress = nil, {}
Manager.install(item, "/dict", function(ok, err)
    install_result = { ok, err }
end, function(...)
    progress[#progress + 1] = { ... }
end)
Assert.is_true(Manager._downloading)
Assert.is_nil(install_result)
Assert.eq(progress[1][1], "part")
Assert.eq(progress[1][2], 5)
Assert.eq(progress[1][3], 5)
Assert.eq(progress[2][1], "install")
-- 安装 Job 被桩住不回调，手动复位在飞标记供后续用例。
Manager._downloading = false

-- 未完成分片走 Request.download，按实际接收字节上报进度，而不是等整片写完才跳格。
part_present = false
progress = {}
Manager.install(item, "/dict", function() end, function(...)
    progress[#progress + 1] = { ... }
end)
Assert.eq(download_call.dest, "/tmp/dict-xhzd.dl/xhzd.part.001")
Assert.matches(download_call.opts.url, "/xhzd%.part%.001$")
download_call.opts.on_progress(3)
Assert.eq(progress[1][2], 3)
download_call.opts.on_progress(5)
Assert.eq(progress[2][2], 5)
part_present = true
download_call.cb(true)
Assert.eq(progress[3][1], "part")
Assert.eq(progress[4][1], "install")
Manager._downloading = false

-- 下载失败：删坏片、复位在飞标记并回调失败。
part_present = false
local failed
local original_remove = os.remove
local removed_part
os.remove = function(path) removed_part = path; return true end
Manager.install(item, "/dict", function(ok, err) failed = { ok, err } end)
download_call.cb(false, "HTTP 404")
os.remove = original_remove
Assert.is_false(failed[1])
Assert.eq(failed[2], "HTTP 404")
Assert.eq(removed_part, "/tmp/dict-xhzd.dl/xhzd.part.001")
Assert.is_false(Manager._downloading)

target_mode = "link"
Assert.is_false(Manager.isInstalled("/dict", "xhzd"))
local removed, remove_err = Manager.remove({ data_dir = "/dict" }, "xhzd")
Assert.is_false(removed)
Assert.eq(remove_err, "dictionary not installed")

tmp_mode = "link"
local invalid_install
Manager.install(item, "/dict", function(ok, err)
    invalid_install = { ok, err }
end)
Assert.is_false(invalid_install[1])
Assert.eq(invalid_install[2], "invalid download directory")

tmp_mode = "directory"
target_mode = "directory"
local removed_paths = {}
os.remove = function(path)
    removed_paths[#removed_paths + 1] = path
    return true
end
function lfs.dir(path)
    Assert.eq(path, "/dict/book-xhzd")
    local names = { ".", "..", "external" }
    local index = 0
    return function()
        index = index + 1
        return names[index]
    end
end
local removed_dir = Manager.remove({
    data_dir = "/dict",
    init = function() end,
}, "xhzd")
os.remove = original_remove
Assert.is_true(removed_dir)
Assert.eq(removed_paths[1], "/dict/book-xhzd/external")
Assert.eq(removed_paths[2], "/dict/book-xhzd")
