--[[--
book.highlights 离线用例。

@module tests.book.highlights_spec
--]]

local Assert = require("support.assert")

package.preload["ui.reader.session"] = function()
    return { current = function() return nil end }
end
package.preload["db.note"] = function()
    return {
        get = function(_, stable_id, chapter_idx)
            if stable_id == "book-1" and chapter_idx == 0 then
                return {
                    payload = '[{"drawer":"lighten","text":"划线句子","chapter":"序章","pageno":3}]',
                }
            end
            return nil
        end,
        all = function()
            return {
                {
                    source_id = "moon",
                    stable_id = "book-1",
                    payload = '[{"drawer":"lighten","text":"划线句子","chapter":"序章","pageno":3}]',
                },
                {
                    source_id = "moon",
                    stable_id = "book-2",
                    payload = '[{"drawer":"lighten","text":"另一句","chapter":"尾声"}]',
                },
            }
        end,
    }
end
package.preload["db.book"] = function()
    return {
        get = function(_, stable_id)
            if stable_id == "book-1" then
                return { title = "活着", authors = "余华" }
            end
            return { title = "兄弟", authors = "余华" }
        end,
    }
end
package.preload["json"] = function()
    return {
        decode = function(s)
            if s:find("划线") then
                return { { drawer = "lighten", text = "划线句子", chapter = "序章", pageno = 3 } }
            end
            if s:find("另一句") then
                return { { drawer = "lighten", text = "另一句", chapter = "尾声" } }
            end
            return nil
        end,
    }
end
package.preload["l10n"] = function()
    return { apply = function() end }
end
package.preload["gettext"] = function()
    return function(s) return s end
end

local Highlights = require("book.highlights")
local items = Highlights.collect("moon", "book-1", 0)
Assert.eq(#items, 1)
Assert.eq(items[1].text, "划线句子")
local text, source = Highlights.pick("moon", "book-1", 0, 1)
Assert.eq(text, "划线句子")
Assert.is_true(source and source:find("序章"))

local all = Highlights.collectAll()
Assert.len(all, 2)
Assert.eq(all[1].author, "余华")
Assert.eq(all[1].title, "活着")

local first = Highlights.random("不存在")
Assert.is_true(first.text == "划线句子" or first.text == "另一句")
local other = Highlights.random(first.text)
Assert.is_true(other.text ~= first.text)

return true
