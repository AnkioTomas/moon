--[[--
月读同步的执行模块能加载。兜底进度是一行 .po，不碰网络。

@module tests.moon_sync.load_spec
--]]

local Assert = require("support.assert")
package.preload["json"] = function()
    local JSON = require("support.json_stub")
    return { encode = JSON.encode, decode = JSON.decode }
end
package.loaded["json"] = nil
local Run = require("moon_sync.run")
local Reading = require("moon_sync.reading")

Assert.eq(type(Run.start), "function")
Assert.eq(type(Reading.progressLine), "function")
Assert.eq(type(Reading.applyLocalExtra), "function")

local source_id = "moon-sync-spec"
local ProgressDB = require("book.progress_db")
ProgressDB.removeSource(source_id)
ProgressDB.upsertRemote(source_id, "book-1", { fraction = 0.4, chapter_idx = 1, updated_at = 10 })
Assert.is_true(Reading.applyProgress(source_id, "book-1",
    Reading.progressLine({ fraction = 0.9, chapter_idx = 1, updated_at = 50 }), 50))
Assert.eq(ProgressDB.get(source_id, "book-1").fraction, 0.9)

-- 本地还有没推上去的进度时，更新的远端也不能盖。
ProgressDB.upsert(source_id, "book-1", { fraction = 0.2, updated_at = 60 })
Reading.applyProgress(source_id, "book-1",
    Reading.progressLine({ fraction = 0.1, chapter_idx = 1, updated_at = 80 }), 80)
Assert.eq(ProgressDB.get(source_id, "book-1").fraction, 0.2)
