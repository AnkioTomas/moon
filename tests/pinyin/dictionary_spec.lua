--[[--
pinyin.dictionary：音节切分 / 前缀查询 / 降级

ljsqlite3 用内存假库 mock（对齐 tests/utils/db/ 先例），不碰真 sqlite 文件；
只验证 SQL 形态、绑定参数、边界过滤、不可用降级。

@module tests.pinyin.dictionary_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

-- 词库文件存在（lfs mock），ljsqlite3 用假库
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function()
            return { mode = "file", size = 100 }
        end,
    }
end
package.preload["utils.paths"] = function()
    return { pinyinDictPath = function() return "/mock/dictionary.sqlite3" end }
end

local captured = {}
local open_ok = true
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function()
            if not open_ok then
                return nil
            end
            return {
                prepare = function(_, sql)
                    captured[#captured + 1] = sql
                    if sql:find("FROM meta") then
                        return {
                            rows = function()
                                local data = { { "entries", "3" }, { "source_tag", "test" } }
                                local i = 0
                                return function()
                                    i = i + 1
                                    return data[i]
                                end
                            end,
                            close = function() end,
                        }
                    end
                    return {
                        bind1 = function(self, i, v)
                            captured[#captured + 1] = v
                            return self
                        end,
                        rows = function()
                            local data = {
                                { "你好", "ni hao" },
                                { "你好吗", "ni hao ma" },
                                { "牛奶", "niu nai" }, -- 前缀不匹配 "ni hao%"，仅对照
                            }
                            local i = 0
                            return function()
                                i = i + 1
                                return data[i]
                            end
                        end,
                        close = function() end,
                    }
                end,
            }
        end,
    }
end

local Dict = require("pinyin.dictionary")

-- ── 纯逻辑：音节切分与边界 ─────────────────────────────
Assert.eq(Dict.toPrefix("nihao"), "ni hao")
Assert.eq(Dict.toPrefix("zhongguo"), "zhong guo")
Assert.eq(Dict.toPrefix("ni"), "ni")
Assert.eq(Dict.toPrefix("nih"), "ni h") -- 输到一半的音节
Assert.eq(Dict.toPrefix("beijing"), "bei jing")

-- 边界：完整段严格相等，末段可为前缀
Assert.is_true(Dict._boundaryOk("ni hao", "ni hao"))
Assert.is_true(Dict._boundaryOk("ni hao", "ni h"))
Assert.is_true(Dict._boundaryOk("ni huai", "ni h"))
Assert.is_true(Dict._boundaryOk("ni", "ni"))           -- 单段相等
Assert.is_true(Dict._boundaryOk("niu", "ni"))          -- 单段前缀（输到一半）
Assert.is_false(Dict._boundaryOk("niu nai", "ni n"))   -- 首段 niu ≠ ni
Assert.is_false(Dict._boundaryOk("niu", "ni h"))       -- 段数不够

-- ── 查询：LIKE 前缀 + 边界过滤 + 按权重序 ─────────────
Assert.is_true(Dict.isAvailable())
Assert.eq(Dict.entries(), "3")
Assert.eq(Dict.sourceTag(), "test")

local words = Dict.lookup("nihao")
-- 绑定参数是空格分隔前缀 + %
local bound
for _, v in ipairs(captured) do
    if type(v) == "string" and v:match("%%$") then
        bound = v
    end
end
Assert.eq(bound, "ni hao%")
-- mock 返回的三行里，"niu nai" 不满足 LIKE 'ni hao%'（真实库不会返回）；
-- 这里直接断言边界过滤对 LIKE 结果集的二次校验不删正确行
Assert.eq(words[1], "你好")
Assert.eq(words[2], "你好吗")

-- 非字母输入直接空
Assert.len(Dict.lookup("ni3"), 0)
Assert.len(Dict.lookup(""), 0)

-- ── 降级：库打不开 → 空结果，不报错 ───────────────────
open_ok = false
package.loaded["pinyin.dictionary"] = nil
local Dict2 = require("pinyin.dictionary")
Assert.is_false(Dict2.isAvailable())
Assert.eq(Dict2.entries(), nil)
Assert.len(Dict2.lookup("nihao"), 0)

Stubs.flush()
