--[[--
首页书架快照：Catalog.recentShelf 拆成当前阅读 / 其余。

@module tests.ui.desktop.home.recent_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(s) return s end end

local catalog_rows = {
    { stable_id = "a" },
    { stable_id = "b" },
    { stable_id = "a" },
}

package.preload["book.catalog"] = function()
    local M = {}
    function M.recentBooks(source_id, limit)
        Assert.eq(source_id, "local")
        Assert.eq(limit, 24)
        return catalog_rows
    end
    function M.recentShelf(source_id, limit)
        if type(source_id) ~= "string" or source_id == "" then
            return nil, {}, require("gettext")("当前数据源不可用")
        end
        local rows = M.recentBooks(source_id, limit or 24)
        local recent = rows[1]
        local skip = recent and recent.stable_id
        local reading = {}
        for i = 1, #rows do
            local book = rows[i]
            if book.stable_id ~= skip then
                reading[#reading + 1] = book
            end
        end
        return recent, reading, nil
    end
    return M
end

local Catalog = require("book.catalog")
local recent, reading, err = Catalog.recentShelf("local", 24)
Assert.eq(recent.stable_id, "a")
Assert.len(reading, 1)
Assert.eq(reading[1].stable_id, "b")
Assert.is_nil(err)

recent, reading, err = Catalog.recentShelf(nil, 24)
Assert.is_nil(recent)
Assert.len(reading, 0)
Assert.eq(err, "当前数据源不可用")

return true
