--[[--
pinyin.dictionary：音节切分 / 前缀查询 / 降级

ljsqlite3 用内存假库 mock（对齐 tests/utils/db/ 先例），不碰真 sqlite 文件；
只验证 SQL 形态、绑定参数、音节边界、不可用降级。

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
local open_count = 0
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function()
            open_count = open_count + 1
            if not open_ok then
                return nil
            end
            return {
                prepare = function(_, sql)
                    captured[#captured + 1] = sql
                    if sql:find("FROM meta") then
                        return {
                        rows = function()
                            local data = {
                                { "entries", "3" }, { "source_tag", "test" },
                            }
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
                            self._bound = self._bound or {}
                            self._bound[i] = v
                            captured[#captured + 1] = v
                            return self
                        end,
                        rows = function(self)
                            local data = {
                                { "你", "ni" },
                                { "你好", "ni hao" },
                                { "你好吗", "ni hao ma" },
                                { "牛奶", "niu nai" },
                            }
                            local bind = self._bound[1]
                            local function hit(py)
                                if type(bind) ~= "string" then
                                    return false
                                end
                                if not bind:find("*", 1, true) then
                                    return py == bind
                                end
                                -- SQL GLOB：* → .*（测试桩只需要通配符）
                                local parts, start = {}, 1
                                while true do
                                    local s = bind:find("*", start, true)
                                    if not s then
                                        parts[#parts + 1] = bind:sub(start)
                                        break
                                    end
                                    parts[#parts + 1] = bind:sub(start, s - 1)
                                    start = s + 1
                                end
                                for i = 1, #parts do
                                    parts[i] = parts[i]:gsub("(%W)", "%%%1")
                                end
                                return py:find("^" .. table.concat(parts, ".*") .. "$") ~= nil
                            end
                            local i = 0
                            local filtered = {}
                            for _, row in ipairs(data) do
                                if hit(row[2]) then
                                    filtered[#filtered + 1] = { row[1] }
                                end
                            end
                            return function()
                                i = i + 1
                                return filtered[i]
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

-- ── 纯逻辑：音节切分 ────────────────────────────────
local p, complete = Dict.toPrefix("nihao")
Assert.eq(p, "ni hao")
Assert.is_true(complete)
Assert.eq(Dict.toPrefix("zhongguo"), "zhong guo")
Assert.eq(Dict.toPrefix("ni"), "ni")
p, complete = Dict.toPrefix("nih")
Assert.eq(p, "ni h")
Assert.is_false(complete, "半截音节 complete=false")
Assert.eq(Dict.toPrefix("beijing"), "bei jing")
p, complete = Dict.toPrefix("n")
Assert.eq(p, "n")
Assert.is_false(complete)

-- ── 查询：完整音节走 = / GLOB 'x *'；半截走 GLOB 'x*' ──
Assert.is_true(Dict.isAvailable())
Assert.eq(Dict.entries(), "3")
Assert.eq(Dict.sourceTag(), "test")

local words = Dict.lookup("nihao")
Assert.eq(captured[#captured], "ni hao *", "双音节再补 GLOB 'prefix *'")
Assert.matches(captured[#captured - 1], "pinyin GLOB %?", "前缀查询必须保持 GLOB，避免 LIKE 全表扫描")
Assert.eq(words[1], "你好")
Assert.eq(words[2], "你好吗")
Assert.eq(#words, 2, "nihao 不得命中 niu")

local ni = Dict.lookup("ni")
local have = {}
for _, w in ipairs(ni) do
    have[w] = true
end
Assert.is_true(have["你"], "完整 ni 命中单字")
Assert.is_nil(have["你好"], "单音节不做 GLOB 'ni *'（那是全库扫描）")
Assert.is_nil(have["牛奶"], "ni 不得命中 niu")

Assert.len(Dict.lookup("n"), 0, "单字母半截不查库")

local nih = Dict.lookup("nih")
Assert.eq(nih[1], "你好")
Assert.eq(nih[2], "你好吗")

-- 简拼：切不成音节 → GLOB 'n* h*'
local nh = Dict.lookup("nh")
Assert.eq(captured[#captured], "n* h*")
Assert.eq(nh[1], "你好")
Assert.eq(nh[2], "你好吗")
Assert.is_nil((function()
    for _, w in ipairs(nh) do
        if w == "牛奶" then
            return true
        end
    end
end)(), "nh 不得命中 niu nai")

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

-- ── reset：负缓存/旧连接不清掉，下载落新库后状态永远不刷新 ──
do
    open_ok = true -- 模拟词库已下载落盘
    Assert.is_false(Dict2.isAvailable(), "负缓存：不 reset 永远判定不可用")
    local before = open_count
    Dict2.reset()
    Assert.is_true(Dict2.isAvailable(), "reset 后必须重开连接")
    Assert.eq(open_count, before + 1)
    -- 再 reset：连接已开，close 后下次访问重开
    Dict2.reset()
    Assert.is_true(Dict2.isAvailable())
    Assert.eq(open_count, before + 2)
end

Stubs.flush()
