--[[--
lockscreen.components.bookshelf：全屏书架主体。

@module tests.lockscreen.components.bookshelf_spec
--]]

local Assert = require("support.assert")

local shelf = {
    reading = {
        { stable_id = "with-cover", cover = "/covers/with-cover.png" },
        { stable_id = "without-cover" },
    },
    covers = {},
}

package.preload["lockscreen.context"] = function()
    return { bookshelf = function() return shelf end }
end
package.loaded["lockscreen.components.bookshelf"] = nil
package.loaded["lockscreen.context"] = nil

local Bookshelf = require("lockscreen.components.bookshelf")
local blocks = Bookshelf.blocks{ x = 0, y = 0, w = 480, h = 800, pad = 0 }

Assert.eq(Bookshelf.full_screen, true)
Assert.eq(blocks[1].kind, "panel")
Assert.eq(blocks[1].width, 480)
Assert.eq(blocks[1].height, 800)

local image
local placeholder_panels = 0
for _, block in ipairs(blocks) do
    if block.kind == "image" then image = block end
    if block.kind == "panel" and block.color ~= require("ffi/blitbuffer").COLOR_WHITE then
        placeholder_panels = placeholder_panels + 1
    end
end
Assert.not_nil(image)
Assert.eq(image.path, "/covers/with-cover.png")
Assert.is_true(placeholder_panels > 0)

shelf.reading = {}
shelf.covers = {}
local empty = Bookshelf.blocks{ x = 0, y = 0, w = 480, h = 800, pad = 0 }
local empty_text
for _, block in ipairs(empty) do
    if block.text then empty_text = block.text end
end
Assert.eq(empty_text, "书架还是空的")
