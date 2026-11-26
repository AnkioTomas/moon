--[[--
utils.settings_legacy：键从旧分区搬进新文件（新文件已有的值优先），旧分区删键；
与新文件同路径的旧分区跳过；只返回改过的旧分区，不落盘。

@module tests.utils.settings_legacy_spec
--]]

local Assert = require("support.assert")

package.preload["utils.paths"] = function()
    return {
        commonPath = function() return "common" end,
        sectionPath = function(name) return name end,
    }
end

local files = {}
local flushed = 0
local probed = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, name)
        probed[#probed + 1] = path
        return name == "mode" and files[path] and "file" or nil
    end,
}
local function open(path)
    files[path] = files[path] or { data = {}, flush = function() flushed = flushed + 1 end }
    return files[path]
end

package.loaded["utils.settings_legacy"] = nil
local Legacy = require("utils.settings_legacy")

open("common").data = { active_source = "moon", other = 1 }
open("display").data = { ui_scale = 150, ui_theme = "ink" }
open("home").data = { home_recent_list_rows = 3 }

local file = open("ui")
file.data.ui_theme = "paper"
local touched = Legacy.migrate(file, { "ui_scale", "ui_theme", "active_source", "missing" }, open)
Assert.eq(file.data.ui_scale, 150, "旧值搬过来")
Assert.eq(file.data.ui_theme, "paper", "新文件已有的值优先")
Assert.eq(file.data.active_source, "moon")
Assert.is_nil(file.data.missing)
Assert.is_nil(files.display.data.ui_scale, "旧分区删键")
Assert.is_nil(files.display.data.ui_theme, "新文件已有值时旧值也删")
Assert.is_nil(files.common.data.active_source)
Assert.eq(files.common.data.other, 1, "不属于自己的键不动")
Assert.len(touched, 2, "只返回改过的旧分区")
Assert.eq(flushed, 0, "不落盘，由调用方按顺序 flush")

-- 拥有者的文件就是某个旧分区（home / reader / ai）：不从自己搬
local home = open("home")
Assert.len(Legacy.migrate(home, { "home_recent_list_rows" }, open), 0)
Assert.eq(home.data.home_recent_list_rows, 3)

-- 改过名的键：v0.2.0 settings/keyboard.lua 的 enabled → ime 的 hide_key；新文件已有值优先
open("keyboard").data = { enabled = false }
local ime = open("ime")
touched = Legacy.migrate(ime, { "hide_key", "enabled" }, open)
Assert.eq(ime.data.hide_key, false, "关掉收起键的用户升级后仍是关")
Assert.is_nil(ime.data.enabled, "ime 自己的 enabled 不从 keyboard 搬")
Assert.is_nil(files.keyboard.data.enabled, "旧键删掉")
Assert.len(touched, 1)
Assert.eq(touched[1], files.keyboard)
Assert.len(Legacy.migrate(ime, { "hide_key" }, open), 0, "第二次没东西可搬")

-- 额外路径排在旧分区前面：当前文件里的值优先，两边的键都删掉
open("settings/local.lua").data = { webdav_url = "https://current", path = "/books" }
open("common").data.webdav_url = "https://stale"
local sync = open("moon_sync")
touched = Legacy.migrate(sync, { "webdav_url" }, open, { "settings/local.lua" })
Assert.eq(sync.data.webdav_url, "https://current", "源配置比旧分区新，先搬它")
Assert.is_nil(files["settings/local.lua"].data.webdav_url)
Assert.eq(files["settings/local.lua"].data.path, "/books", "没点名的键留在源配置")
Assert.is_nil(files.common.data.webdav_url, "旧分区里的同名键也删掉")
Assert.eq(#touched, 2)

-- 不存在的旧分区不打开（新装用户每个拥有者都会走一遍迁移，别为它们开 8 个文件）
Legacy.migrate({ data = {} }, { "anything" }, open)
Assert.is_nil(files.reader, "没有的旧分区不会被打开")
Assert.is_true(#probed > 0)
