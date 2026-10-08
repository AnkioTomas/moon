local Assert = require("support.assert")
local JsonStub = require("support.json_stub")

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key" }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

package.preload["source.toc"] = function()
    return {
        read = function() return nil end,
        put = function() return true end,
        drop = function() end,
    }
end

local volumes = {
    { id = 5, name = "哈利波特与魔法石", seriesId = 42, chapters = {
        { id = 11, title = "-100000", titleName = "", format = 3, pages = 120,
          files = { { filePath = "/lib/HP/哈利波特与魔法石.epub" } } },
    } },
    { id = 6, name = "-100000", seriesId = 42, chapters = {
        { id = 12, title = "", titleName = "-100000", format = 3, pages = 130,
          files = { { filePath = "/lib/HP/哈利波特与密室.epub" } } },
    } },
    { id = 7, name = "1", seriesId = 42, chapters = {
        { id = 13, title = "-100000", titleName = "", format = 1, pages = 200,
          files = { { filePath = "/lib/AKIRA/AKIRA Vol.01.zip" } } },
    } },
}
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            local url = opts.url or ""
            if url:match("/api/Series/volumes") then
                cb({ code = 200, body = JsonStub.encode(volumes) })
            elseif url:match("/api/Series/%d+") then
                cb({ code = 200, body = JsonStub.encode({ id = 42, libraryId = 8 }) })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local Kavita = require("source.kavita")
local toc
Kavita.new():loadTocAsync({ source_id = "kavita", stable_id = "42" }, function(t) toc = t end)

Assert.not_nil(toc)
Assert.len(toc, 3)
Assert.eq(toc[1].toc_version, 3)
-- title 是 -100000 哨兵 → 退回有意义的卷名
Assert.eq(toc[1].title, "哈利波特与魔法石")
Assert.eq(toc[1].volume_name, "哈利波特与魔法石")
Assert.eq(toc[1].file_name, "哈利波特与魔法石")
-- titleName 也是哨兵、卷名也是哨兵 → 退回文件名
Assert.eq(toc[2].title, "哈利波特与密室")
Assert.eq(toc[2].volume_name, nil)
Assert.eq(toc[2].file_name, "哈利波特与密室")
-- 漫画：无章元数据、卷名是纯数字卷号（不算标题）→ 退回文件名
Assert.eq(toc[3].title, "AKIRA Vol.01")
Assert.eq(toc[3].volume_name, "1")
Assert.eq(toc[3].file_name, "AKIRA Vol.01")
