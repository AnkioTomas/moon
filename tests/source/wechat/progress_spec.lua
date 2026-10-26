--[[--
微信进度原文缓存与章节壳层的坐标回归。

@module tests.source.wechat.progress_spec
--]]

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.preload["json"] = function() return JSON end

local fetched = 0
local source = "<html><body><p>原始正文与章节末尾</p></body></html>"
package.preload["source.wechat.chapter"] = function()
    return {
        fetchHtmlAsync = function(_id, _chapter, cb)
            fetched = fetched + 1
            cb(source, nil, source, "html")
        end,
    }
end
local Position = require("source.wechat.progress")
local Paths = require("utils.paths")
local identity = { source_id = "wechat", stable_id = "progress-coordinate-spec" }
local chapter = { idx = 1, uid = "old", title = "章名" }
local path = Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/1.position.json"
local local_path = Paths.chapterPath(identity.stable_id, 1, identity.source_id)
os.remove(path)
os.remove(local_path)

local ok, err = Position.remember(identity.stable_id, chapter, source, "html")
Assert.is_true(ok)
Assert.is_nil(err)
local raw, format
Position.loadAsync(identity, chapter, function(s, f) raw, format = s, f end)
Assert.eq(raw, source)
Assert.eq(format, "html")
Assert.eq(fetched, 0, "相同章节原文命中缓存，不联网")

chapter.uid = "new"
Position.loadAsync(identity, chapter, function(s, f) raw, format = s, f end)
Assert.eq(fetched, 1, "章节 uid 变化不能复用旧原文")
Assert.eq(raw, source)
Position.loadAsync(identity, chapter, function(s) raw = s end)
Assert.eq(fetched, 1)

local pos = { fraction = 0.5, extra = { chapter_offset = 16 } }
Assert.is_true(Position.localize(identity, chapter, pos, source, "html"))
Assert.eq(pos.locator, "/html/body/p/text().1")
Assert.eq(Position.encode(identity, chapter, pos, source, "html"), 16)

pos = { fraction = 0.5, extra = { chapter_offset = 1 } }
Assert.is_true(Position.localize(identity, chapter, pos, "一行正文\n第二行", "txt"))
Assert.eq(pos.locator, "/html/body/p[1]/text().1", "TXT 的标题与章节壳层不能改变原文字符坐标")
Assert.eq(Position.encode(identity, chapter, pos, "一行正文\n第二行", "txt"), 1)
Assert.eq(Position.encode(identity, chapter, { fraction = 0, chapter_fraction = 0 }, source, "html"), 0)
Assert.not_nil(Position.encode(identity, chapter, { fraction = 1, chapter_fraction = 1 }, source, "html"))
local offset, _summary, _fraction, reason = Position.encode(identity, chapter, { fraction = 0.5 }, source, "html")
Assert.is_nil(offset)
Assert.eq(reason, "无法定位阅读进度")

local open = io.open
io.open = function(filename, mode)
    if filename == path .. ".part" then return nil, "read-only cache" end
    return open(filename, mode)
end
ok, err = Position.remember(identity.stable_id, chapter, source, "html")
io.open = open
Assert.is_nil(ok)
Assert.eq(err, "read-only cache")
os.remove(path)
