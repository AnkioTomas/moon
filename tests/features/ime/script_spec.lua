--[[--
features.ime.script：候选词简繁转换（ljsqlite3 用内存桩代替，表内容取 opencc.sqlite3 的真实条目）。
@module tests.features.ime.script_spec
--]]
local Assert = require("support.assert")

local TABLES = {
    meta = { s2t_max = "3", t2s_max = "2" },
    s2t = { ["发"] = "發", ["头"] = "頭", ["头发"] = "頭髮", ["后"] = "後", ["皇后"] = "皇后", ["来"] = "來",
        ["发展"] = "發展", ["干"] = "幹", ["内"] = "內" },
    t2s = { ["發"] = "发", ["頭"] = "头", ["髮"] = "发", ["後"] = "后", ["來"] = "来", ["乾"] = "干", ["幹"] = "干" },
}
local queries = {}
package.loaded["lua-ljsqlite3/init"] = {
    open = function(path, mode)
        Assert.matches(path, "features/ime/opencc%.sqlite3$")
        Assert.eq(mode, "ro")
        return {
            prepare = function(_conn, sql)
                local tbl = sql:match("FROM (%w+)")
                local params = {}
                if tbl == "meta" then params = { "s2t_max", "t2s_max" } end
                queries[#queries + 1] = { tbl = tbl, params = params }
                return {
                    bind1 = function(_stmt, i, v) params[i] = v end,
                    rows = function()
                        local i = 0
                        return function()
                            while i < #params do
                                i = i + 1
                                local v = TABLES[tbl][params[i]]
                                if v then return { params[i], v } end
                            end
                        end
                    end,
                    close = function() end,
                }
            end,
        }
    end,
}

local Script = require("features.ime.script")

Assert.eq(table.concat(Script.convertWords({ "发展", "头发", "皇后", "后来", "内耗" }, "traditional"), ","),
    "發展,頭髮,皇后,後來,內耗", "词组优先，皇后 不能逐字错成 皇後")
Assert.eq(#queries, 2, "开库读一次 meta，整批候选只查一次")
Assert.eq(queries[2].tbl, "s2t")
Assert.contains(queries[2].params, "头发")
Assert.eq(#queries[2].params, 13, "子串去重：5 个双字词 15 个子串，发 / 后 重复只查一次")

Assert.eq(table.concat(Script.convertWords({ "頭髮", "後來發", "abc 1，你", "" }, "simplified"), ","),
    "头发,后来发,abc 1，你,", "未命中原样保留，空串也是一个候选")
Assert.eq(queries[3].tbl, "t2s")

Assert.eq(table.concat(Script.convertWords({ "乾", "干", "幹", "後" }, "simplified"), ","), "干,后",
    "转换后重复只留第一个，保序")

local many = {}
for i = 1, 600 do many[i] = string.format("w%03d", i) end
local before = #queries
Assert.len(Script.convertWords(many, "traditional"), 600)
Assert.is_true(#queries - before > 1, "超过 500 个参数分块查询")
for i = before + 1, #queries do Assert.is_true(#queries[i].params <= 500) end
