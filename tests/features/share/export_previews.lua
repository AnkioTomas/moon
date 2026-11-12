--[[--
把关键书摘样式导出为 1125 宽预览图，供对照设计稿。
在仓库根执行：luajit tests/features/share/export_previews.lua [输出目录]

@module tests.features.share.export_previews
--]]

-- 既可经 tests/features/share/run_export.lua 引导（推荐），也可在已挂好
-- 原生库与 Device 的环境里直接跑。这里只确保彩屏路径和 blitbuffer 不是桩。
local Config = require("support.config")
if not Config.setupNativePath() then
    error("需要 KOReader 模拟器原生库才能导出预览")
end

-- 导出预览按彩屏设计稿走，避免被灰度路径收成单色。
-- 不要卸载 ffi/blitbuffer：mupdf 可能已经 cdef 过，再 require 会 redefine。
local Device = require("device")
if Device.screen then
    Device.screen.isColorEnabled = function() return true end
end

package.loaded["features.share.card"] = nil
package.loaded["features.lockscreen.render"] = nil
local Card = require("features.share.card")

local SAMPLE = "明月几时有？把酒问青天。不知天上宫阙，今夕是何年。我欲乘风归去，又恐琼楼玉宇，高处不胜寒。"
local payload = {
    text = SAMPLE,
    title = "东坡乐府",
    authors = "苏轼",
    chapter = "水调歌头",
    cover = Card.logoPath(),
}

local out = arg[1] or "previews"
local lfs = require("libs/libkoreader-lfs")
if lfs.attributes(out, "mode") ~= "directory" then
    assert(lfs.mkdir(out))
end

-- 日历用固定上海日期，避免每次导出对不上。UTC 2026-11-12 10:00 → 上海 18:00。
local now = 1794477600
local jobs = {
    { name = "paper", style = "paper", opts = {} },
    { name = "paper-night", style = "paper", opts = { swatch = "night" } },
    { name = "classic", style = "classic", opts = {} },
    { name = "letter", style = "letter", opts = {} },
    { name = "brocade", style = "brocade", opts = {} },
    { name = "cinema", style = "cinema", opts = {} },
    { name = "calendar", style = "calendar", opts = { now = now } },
    { name = "scenic-sunset", style = "scenic", opts = { art = "sunset" } },
    { name = "scenic-window", style = "scenic", opts = { art = "window" } },
    { name = "scenic-short", style = "scenic", opts = { art = "sunset" }, text = "明月几时有？" },
    { name = "vista-dawn", style = "vista", opts = { art = "dawn" } },
}

local failed = 0
for _idx, job in ipairs(jobs) do
    local path = out .. "/share-" .. job.name .. ".png"
    local used = payload
    if job.text then
        used = {}
        for k, v in pairs(payload) do used[k] = v end
        used.text = job.text
    end
    local ok, err, layout = Card.write(job.style, used, path, Card.OUTPUT_WIDTH, job.opts)
    if not ok then
        failed = failed + 1
        io.stderr:write("FAIL ", job.name, " ", tostring(err), "\n")
    else
        io.stdout:write("OK ", path, " ", layout.width, "x", layout.height, "\n")
    end
end
if failed > 0 then error("预览导出失败 " .. failed .. " 张") end
