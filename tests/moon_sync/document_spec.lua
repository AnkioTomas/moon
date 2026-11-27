--[[-- 月读同步把 sync.document 的文档拉下来、合并、写回；内容没变不再上传。 --]]

local Assert = require("support.assert")

package.preload["json"] = function()
    local JSON = require("support.json_stub")
    return { encode = JSON.encode, decode = JSON.decode }
end
package.loaded["json"] = nil
package.loaded["moon_sync.run"] = nil

local Run = require("moon_sync.run")
local Ext = require("utils.extension")

local doc = {
    { { "rss", "https://a.example/rss", "Alpha", "g", "", 1, 0, 3,
        { { "guid-1", "Title", "https://a.example/1", 10, 1, 1, 8, 0, 0 } } } },
    { { "rss", "https://old.example/rss", 2 } },
}
local imported = 0
local bad = 0
Ext.add("sync.document", {
    id = "demo-doc",
    export = function() return doc end,
    merge = function(local_doc, remote_doc)
        if type(remote_doc) == "table" and type(remote_doc[1]) == "table" and remote_doc[1][1] ~= nil then
            return remote_doc
        end
        return local_doc
    end,
    import = function()
        imported = imported + 1
        return true
    end,
})
Ext.add("sync.document", {
    id = "../nope",
    export = function() bad = bad + 1; return {} end,
    merge = function() return {} end,
    import = function() return true end,
})

local store, puts = {}, 0
local dav = {
    getAsync = function(_self, path, dest, _opts, cb)
        local body = store[path]
        if not body then
            cb(false, "missing", 404)
        else
            local file = assert(io.open(dest, "wb"))
            file:write(body)
            file:close()
            cb(true)
        end
        return { cancel = function() end }
    end,
    ensurePathAsync = function(_self, _path, cb)
        cb(true)
        return { cancel = function() end }
    end,
    putFileAsync = function(_self, path, src, cb)
        local file = assert(io.open(src, "rb"))
        store[path] = file:read("*a")
        file:close()
        puts = puts + 1
        cb(true)
        return { cancel = function() end }
    end,
}

local function round()
    local done, err
    Run.documents({ cancelled = false }, dav, "/box", function(ok, step_err)
        done, err = ok, step_err
    end)
    Assert.is_true(done, err)
end

round()
Assert.eq(imported, 1)
Assert.eq(puts, 1)
Assert.eq(bad, 0, "非法 id 不参与")
local path = "/box/.moon-koreader/reading/demo-doc.json"
Assert.not_nil(store[path])

round()
Assert.eq(imported, 2, "没变也要写进本地")
Assert.eq(puts, 1, "和远端一样就不再上传")

return true
