--[[--
source.legacy_ext：ext.kavita / ext.bookorbit 并入内置源的一次性迁移

@module tests.source.legacy_ext_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

local execs = {}
local schema = {
    sqlite_master = { "books", "xray_entities", "http" },
    books = { "source_id", "stable_id", "path" },
    xray_entities = { "cid", "source_id" },
    http = { "cid", "url" },
}
package.preload["utils.db"] = function()
    return {
        query = function(sql)
            if sql:find("sqlite_master", 1, true) then
                return { schema.sqlite_master }, #schema.sqlite_master
            end
            local cols = schema[sql:match("table_info%(([%w_]+)%)")]
            return { {}, cols }, #cols
        end,
        exec = function(sql, ...)
            execs[#execs + 1] = { sql = sql, args = { ... } }
            return true
        end,
    }
end
package.preload["utils.paths"] = function()
    return {
        sourcePath = function(id) return "settings/" .. id .. ".lua" end,
        sourceCacheDir = function(id) return "cache/" .. id end,
    }
end
local existing = { ["settings/ext.kavita.lua"] = true, ["cache/ext.kavita"] = true, ["cache/ext.bookorbit"] = true,
    ["cache/bookorbit"] = true }
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path) return existing[path] and "file" or nil end }
end

local source = { active_source = "ext.kavita", enabled_sources = { ["ext.kavita"] = false } }
local home = { home_widgets = { { id = "ext.kavita.on_deck", page = 1 }, { id = "clock", page = 1 } } }
local saved = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner) return owner == "source" and source or home end,
        save = function(owner) saved[#saved + 1] = owner end,
    }
end
package.preload["utils.log"] = function() return { warn = function() end } end

local renamed = {}
local real_rename = os.rename
os.rename = function(from, to) renamed[#renamed + 1] = from .. ">" .. to; return true end

local Legacy = require("source.legacy_ext")
Legacy.run()
os.rename = real_rename

local updated = {}
for _idx, e in ipairs(execs) do
    local tbl = e.sql:match("^UPDATE OR IGNORE ([%w_]+)")
    if tbl and not updated[tbl] then updated[tbl] = e.args end
end
Assert.eq(updated.books[1], "kavita", "带 source_id 的表改 id")
Assert.not_nil(updated.xray_entities, "feature 的表也迁")
Assert.is_nil(updated.http, "没有 source_id 列的表不碰")

local path_fix
for _idx, e in ipairs(execs) do
    if e.sql:find("replace(path", 1, true) and e.sql:find("UPDATE books", 1, true) and e.args[1] == "/cache/ext.kavita/" then
        path_fix = e.args
    end
end
Assert.eq(path_fix[2], "/cache/kavita/", "书记的缓存路径跟着换")

Assert.eq(table.concat(renamed, ";"), "settings/ext.kavita.lua>settings/kavita.lua;cache/ext.kavita>cache/kavita",
    "目标不存在才改名；新 id 已有目录不覆盖")
Assert.eq(source.active_source, "kavita")
Assert.eq(source.enabled_sources["kavita"], false)
Assert.is_nil(source.enabled_sources["ext.kavita"])
Assert.eq(home.home_widgets[1].id, "kavita.on_deck", "首页组件 id 跟着换")
Assert.eq(home.home_widgets[2].id, "clock")
Assert.is_true(source.legacy_ext_done)

local before = #execs
Legacy.run()
Assert.eq(#execs, before, "做完不再扫表")
