--[[--
pinyin.dictionary：音节切分 / 短码索引 / 长码降级

ljsqlite3 用内存假库 mock（对齐 tests/utils/db/ 先例），不碰真 sqlite 文件；
只验证 schema、绑定参数、音节边界、不可用降级。

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
local prepare_count = 0
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function()
            open_count = open_count + 1
            if not open_ok then
                return nil
            end
            return {
                prepare = function(_, sql)
                    prepare_count = prepare_count + 1
                    captured[#captured + 1] = sql
                    if sql:find("FROM meta") then
                        return {
                        rows = function()
                            local data = {
                                { "schema_version", "2" }, { "entries", "3" }, { "source_tag", "test" },
                            }
                            local i = 0
                            return function()
                                i = i + 1
                                return data[i]
                            end
                        end,
                            close = function() end,
                            step = function()
                                return { "2" }
                            end,
                        }
                    end
                    return {
                        bind1 = function(self, i, v)
                            self._bound = self._bound or {}
                            self._bound[i] = v
                            captured[#captured + 1] = v
                            return self
                        end,
                        clearbind = function(self)
                            self._bound = {}
                            return self
                        end,
                        reset = function(self)
                            return self
                        end,
                        rows = function(self)
                            local data = {
                                { "你", "ni", "n" },
                                { "你好", "nihao", "nh" },
                                { "你好吗", "nihaoma", "nhm" },
                                { "牛奶", "niunai", "nn" },
                                { "江枫渔火对愁眠", "jiangfengyuhuoduichoumian", "jfyhdcm" },
                            }
                            local bind = sql:find("FROM quick") and self._bound[2] or self._bound[1]
                            local function hit(row)
                                if type(bind) ~= "string" then
                                    return false
                                end
                                local value = sql:find("initials") and row[3] or row[2]
                                if sql:find("FROM quick") then
                                    if self._bound[1] == "direct" and (bind == "nih" or bind == "nihao") then
                                        return row[2]:find("^" .. bind) ~= nil
                                    end
                                    if self._bound[1] == "abbrev" and bind == "nh" then
                                        return row[3]:find("^nh") ~= nil
                                    end
                                    return false
                                end
                                if not bind:find("*", 1, true) then
                                    return value == bind
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
                                return value:find("^" .. table.concat(parts, ".*") .. "$") ~= nil
                            end
                            local i = 0
                            local filtered = {}
                            for _, row in ipairs(data) do
                                if hit(row) then
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

-- ── 查询：短码直接命中构建期索引；长码才走 words 索引 ──
Assert.is_true(Dict.isAvailable())
Assert.eq(Dict.entries(), "3")
Assert.eq(Dict.sourceTag(), "test")

local words = Dict.lookup("nihao")
Assert.eq(captured[#captured], "nihao", "六位以内的直接拼音必须等值命中 quick")
Assert.eq(words[1], "你好")
Assert.eq(words[2], "你好吗")
Assert.eq(#words, 2, "nihao 不得命中 niu")

-- 高频输入复用已编译语句，避免每次按键都解析同一段 SQL。
local prepared_after_first_lookup = prepare_count
Dict.lookup("nihao")
Assert.eq(prepare_count, prepared_after_first_lookup, "重复查同一码不得重新 prepare SQL")

-- 超过预计算范围才走原始 code 前缀索引。
local long = Dict.lookup("nihaom")
Assert.eq(long[1], "你好吗")
Assert.eq(captured[#captured], "nihaom*", "长码直接用无空格 code 前缀")
Assert.matches(captured[#captured - 1], "code GLOB %?", "长码只查询 code 索引")

local ni = Dict.lookup("ni")
local have = {}
for _, w in ipairs(ni) do
    have[w] = true
end
Assert.is_true(have["你"], "完整 ni 命中单字")
Assert.is_nil(have["你好"], "单音节只做 code 精确查询")
Assert.is_nil(have["牛奶"], "ni 不得命中 niu")

Assert.len(Dict.lookup("n"), 0, "单字母半截不查库")

local nih = Dict.lookup("nih")
Assert.eq(nih[1], "你好")
Assert.eq(nih[2], "你好吗")
Assert.eq(captured[#captured], "nih", "三位直接拼音必须等值命中 quick")

-- 简拼：切不成音节 → 等值命中 quick，运行期不再构造 n* h*。
local nh = Dict.lookup("nh")
Assert.eq(captured[#captured], "nh")
Assert.eq(nh[1], "你好")
Assert.eq(nh[2], "你好吗")
Assert.is_nil((function()
    for _, w in ipairs(nh) do
        if w == "牛奶" then
            return true
        end
    end
end)(), "nh 不得命中 niu nai")

-- 长句简拼每个音节只取一个首字母。
local poem = Dict.lookup("jfyhdcm")
Assert.eq(poem[1], "江枫渔火对愁眠")
local poem_with_initial = Dict.lookup("jfyhdchm")
Assert.eq(poem_with_initial[1], "江枫渔火对愁眠", "ch 声母展开简拼必须归一到标准首字母")

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
