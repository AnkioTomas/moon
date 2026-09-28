--[[--
source.kindle.client：借道 kindle.koplugin 模块，缓存目录与它共用。

@module tests.source.kindle.client_spec
--]]

local Assert = require("support.assert")

local cc_db_exists = true
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path, field)
        Assert.eq(path, "/var/local/cc.db")
        Assert.eq(field, "mode")
        return cc_db_exists and "file" or nil
    end }
end
package.preload["datastorage"] = function()
    return { getFullDataDir = function() return "/ko" end }
end

local kindle_settings
_G.G_reader_settings = {
    readSetting = function(_, key)
        Assert.eq(key, "kindle_plugin")
        return kindle_settings
    end,
}

package.preload["lua/ccdb_scanner"] = function()
    return { new = function()
        return { scan = function() return { { id = "cc:a" } } end }
    end }
end

local helpers, managers = {}, {}
package.preload["lua/helper_client"] = function()
    return { new = function()
        local helper = {}
        function helper:setSettings(s) self.settings = s end
        helpers[#helpers + 1] = helper
        return helper
    end }
end
local fresh = {}
package.preload["lua/cache_manager"] = function()
    return { new = function(_, helper)
        local manager = { helper = helper }
        function manager:setSettings(s) self.settings = s end
        function manager:isFresh(kbook)
            return fresh[kbook.id] == true, self.settings.cache_dir .. "/" .. kbook.id .. ".epub"
        end
        function manager:ensureCachedEpub(kbook)
            if kbook.id == "cc:bad" then return nil, "conversion_failed" end
            return self.settings.cache_dir .. "/" .. kbook.id .. ".epub"
        end
        managers[#managers + 1] = manager
        return manager
    end }
end
package.preload["lua/virtual_library"] = function()
    return { getBlockedReasonText = function(_, book) return "text:" .. book.block_reason end }
end

local Client = require("source.kindle.client")

-- 可用：cc.db 存在且 kindle.koplugin 模块可 require；结果按进程缓存。
Assert.is_true(Client.available())
cc_db_exists = false
Assert.is_true(Client.available(), "插件增删需重启，available 不重复探测")

Assert.eq(Client.scan()[1].id, "cc:a")

-- 未配置 cache_dir 时跟 kindle.koplugin 默认目录一致；cache_manager 与 helper 同一份设置。
kindle_settings = nil
Assert.is_nil(Client.readyPath({ id = "cc:a", open_mode = "convert" }))
Assert.eq(managers[1].settings.cache_dir, "/ko/cache/kindle.koplugin")
Assert.eq(helpers[1].settings.cache_dir, "/ko/cache/kindle.koplugin")
Assert.eq(managers[1].helper, helpers[1])

-- 用户改过 cache_dir：沿用，且不改写 kindle.koplugin 的设置表。
kindle_settings = { cache_dir = "/mnt/us/kcache", sync_reading_state = true }
fresh["cc:a"] = true
Assert.eq(Client.readyPath({ id = "cc:a", open_mode = "convert" }), "/mnt/us/kcache/cc:a.epub")
Assert.eq(kindle_settings.cache_dir, "/mnt/us/kcache")
Assert.is_true(managers[#managers].settings ~= kindle_settings)

-- direct 直接原文件；blocked 永远不可打开。
Assert.eq(Client.readyPath({ id = "cc:b", open_mode = "direct", source_path = "/docs/b.azw3" }), "/docs/b.azw3")
Assert.is_nil(Client.readyPath({ id = "cc:c", open_mode = "blocked", source_path = "/docs/c.mobi" }))

-- prepare 透传 cache_manager 的路径 / 失败码。
Assert.eq(Client.prepare({ id = "cc:x" }), "/mnt/us/kcache/cc:x.epub")
local path, code = Client.prepare({ id = "cc:bad" })
Assert.is_nil(path)
Assert.eq(code, "conversion_failed")

Assert.eq(Client.reasonText("drm"), "text:drm")
