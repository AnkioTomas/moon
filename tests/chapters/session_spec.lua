--[[--
chapters session / lifecycle 离线用例

@module tests.chapters.session_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Fakes = require("support.chapter_fakes")
Stubs.install()
Stubs.reset()
Fakes.install()

package.loaded["chapters.session"] = nil
package.loaded["chapters.materialize"] = nil
package.loaded["chapters.navigate"] = nil
package.loaded["chapters.html"] = nil
package.loaded["chapters"] = nil
package.loaded["chapters.init"] = nil

local Chapters = require("chapters")

local ref = { book_key = "k1", source_id = "wechat", stable_id = "b1" }
local toc = {
    { idx = 1, title = "一", uid = "u1" },
    { idx = 2, title = "二", uid = "u2" },
    { idx = 3, title = "三", uid = "u3" },
}

Chapters.bind({
    plugin = { emitToSource = function() end },
    source = {},
    book = { title = "书" },
    ref = ref,
    toc = toc,
    idx = 1,
})
Assert.is_true(Chapters.isActive())
Assert.eq(Chapters.currentIdx(), 1)
Assert.eq(Chapters.chapterCount(), 3)
local gen1 = Chapters.generation()

Chapters.bind({
    plugin = {},
    source = {},
    book = {},
    ref = ref,
    toc = toc,
    idx = 2,
})
Assert.eq(Chapters.currentIdx(), 2)
Assert.is_true(Chapters.generation() > gen1)

Chapters.beginSwitch("/tmp/2.html", "k1")
Assert.is_true(Chapters.hasPendingSwitch())
Assert.is_false(Chapters.onCloseDocument("/tmp/1.html"))
Assert.is_true(Chapters.isActive())
Assert.is_false(Chapters.hasPendingSwitch())

Assert.is_true(Chapters.onCloseDocument("/tmp/2.html"))
Assert.is_false(Chapters.isActive())
Assert.eq(Chapters.currentIdx(), nil)
