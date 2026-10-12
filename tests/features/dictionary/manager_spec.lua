--[[-- features.dictionary.manager：资源清单校验。 --]]

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
    return { root = function() return "/tmp" end, ensureDir = function() return true end }
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

local job
package.preload["workers.job"] = function()
    return { run = function(fn, opts) job = { fn = fn, opts = opts } end }
end
G_reader_settings = { saved = {}, saveSetting = function(self, key, value) self.saved[key] = value end }

local Manager = require("features.dictionary.manager")
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
Assert.is_nil(install_result)
Assert.eq(progress[1][1], "part")
Assert.eq(progress[1][2], 5)
Assert.eq(progress[1][3], 5)
Assert.eq(progress[2][1], "install")
Assert.eq(job.opts.kind, "heavy")

-- 安装失败：分片留着续传，只删与分片同样大的拼接包。
local original_remove = os.remove
local removed_on_fail = {}
os.remove = function(path) removed_on_fail[#removed_on_fail + 1] = path; return true end
job.opts.on_failed("dictionary sha256 mismatch")
os.remove = original_remove
Assert.eq(removed_on_fail[1], "/tmp/dict-xhzd.dl/archive.part")
Assert.len(removed_on_fail, 1)
Assert.is_false(install_result[1])
Assert.eq(install_result[2], "dictionary sha256 mismatch")

-- 同一词典的并发由任务队列去重，Manager 不再拒绝第二个安装。
install_result = nil
Manager.install(item, "/dict", function(ok, err) install_result = { ok, err } end)
Assert.is_nil(install_result, "不再有模块级在飞标记")

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

-- 下载失败：删坏片、复位在飞标记并回调失败。
part_present = false
local failed
local removed_part
os.remove = function(path) removed_part = path; return true end
Manager.install(item, "/dict", function(ok, err) failed = { ok, err } end)
download_call.cb(false, "HTTP 404")
os.remove = original_remove
Assert.is_false(failed[1])
Assert.eq(failed[2], "HTTP 404")
Assert.eq(removed_part, "/tmp/dict-xhzd.dl/xhzd.part.001")

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
local disabled = { ["/dict/book-xhzd/xhzd.ifo"] = true, ["/dict/other/a.ifo"] = true }
local removed_dir = Manager.remove({
    data_dir = "/dict",
    dicts_disabled = disabled,
    init = function() end,
}, "xhzd")
os.remove = original_remove
Assert.is_true(removed_dir)
Assert.eq(removed_paths[1], "/dict/book-xhzd/external")
Assert.eq(removed_paths[2], "/dict/book-xhzd")
Assert.is_nil(disabled["/dict/book-xhzd/xhzd.ifo"], "删掉的词典不留禁用记录")
Assert.is_true(disabled["/dict/other/a.ifo"])
Assert.eq(G_reader_settings.saved.dicts_disabled, disabled)

-- KOReader 也读 <dir>_ext：列表与「设为当前」都要覆盖，否则 _ext 词典停不掉也看不见。
local tree = {
    ["/dict"] = { "a", "res" },
    ["/dict/a"] = { "a.ifo", "a.idx" },
    ["/dict/res"] = { "x.ifo" },
    ["/dict_ext"] = { "b.IFO" },
}
function lfs.dir(path)
    local names = assert(tree[path], "no such dir")
    local index = 0
    return function()
        index = index + 1
        return names[index]
    end
end
function lfs.attributes(path, name)
    local mode = tree[path] and "directory" or "file"
    return name == "mode" and mode or { mode = mode }
end
local listed = Manager.list("/dict")
Assert.eq(table.concat(listed, ","), "/dict/a/a.ifo,/dict_ext/b.IFO")
tree["/dict_ext"] = nil
Assert.eq(table.concat(Manager.list("/dict"), ","), "/dict/a/a.ifo", "没有 _ext 目录不报错")
tree["/dict_ext"] = { "b.IFO" }

local sdcv_updates = 0
local reader_dict = {
    data_dir = "/dict",
    dicts_disabled = { ["/dict/a/a.ifo"] = true },
    updateSdcvDictNamesOptions = function() sdcv_updates = sdcv_updates + 1 end,
}
Manager.activate(reader_dict, "/dict/a/a.ifo")
Assert.is_nil(reader_dict.dicts_disabled["/dict/a/a.ifo"])
Assert.is_true(reader_dict.dicts_disabled["/dict_ext/b.IFO"], "_ext 词典也要停用")
Assert.eq(G_reader_settings.saved.dicts_disabled, reader_dict.dicts_disabled)
Assert.eq(sdcv_updates, 1)
G_reader_settings = nil
