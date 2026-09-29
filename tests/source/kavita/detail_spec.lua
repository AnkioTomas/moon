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

local db_intro
package.preload["db.book"] = function()
    return { get = function() return { source_id = "kavita", stable_id = "42", intro = db_intro } end }
end

local remembers = {}
package.preload["book.store"] = function()
    return {
        rememberMany = function(rows)
            remembers[#remembers + 1] = rows
            db_intro = rows[1].intro
        end,
    }
end

local metadata_calls = 0
package.preload["http.request"] = function()
    return {
        request = function(opts, cb)
            if (opts.url or ""):match("/api/Series/metadata") then
                metadata_calls = metadata_calls + 1
                cb({
                    code = 200,
                    body = JsonStub.encode({
                        seriesId = 42, summary = "S42", writers = { { name = "W42" } },
                    }),
                })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

local Kavita = require("source.kavita")
local source = Kavita.new()

-- 已配置：拉 metadata 写回并回传最新书行
local got, gerr
source:getDetailAsync({ source_id = "kavita", stable_id = "42" }, function(d, e) got, gerr = d, e end)
Assert.is_nil(gerr)
Assert.eq(metadata_calls, 1)
Assert.len(remembers, 1)
Assert.eq(remembers[1][1].intro, "S42")
Assert.eq(remembers[1][1].authors, "W42")
Assert.not_nil(got)
Assert.eq(got.intro, "S42")

-- 未配置：直接回退到身份携带的书行，不发请求
cfg = { base_url = "", api_key = "" }
local calls_before = metadata_calls
local fallback
Kavita.new():getDetailAsync({
    source_id = "kavita", stable_id = "42", book = { intro = "local only" },
}, function(d) fallback = d end)
Assert.eq(metadata_calls, calls_before)
Assert.not_nil(fallback)
Assert.eq(fallback.intro, "local only")
