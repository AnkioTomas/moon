--[[-- dictionary.manager：资源清单校验。 --]]

local Assert = require("support.assert")

package.preload["json"] = function() return {} end
package.preload["http.request"] = function() return {} end
package.preload["utils.paths"] = function()
    return { root = function() return "/tmp" end, ensureSettings = function() end }
end
package.preload["util"] = function()
    return { makePath = function() return true end }
end

local target_mode
local tmp_mode = "directory"
local lfs = {}
function lfs.attributes(path, name)
    local attr
    if path == "/tmp/dict-xhzd.dl/xhzd.part.001" then
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

local abort_self
local worker_job = {
    abort = function(self)
        abort_self = self
    end,
}
package.preload["workers.job"] = function()
    return {
        run = function()
            return worker_job
        end,
    }
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

local install_result
Manager.install(item, "/dict", function(ok, err)
    install_result = { ok, err }
end)
Assert.is_true(Manager.downloading())
Assert.is_nil(install_result)
Manager.cancel()
Assert.eq(abort_self, worker_job)
Assert.is_false(Manager.downloading())

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
local original_remove = os.remove
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
