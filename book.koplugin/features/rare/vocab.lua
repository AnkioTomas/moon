--[[--
KOReader 生字本（vocabbuilder 插件，settings/vocabulary_builder.sqlite3 的 vocabulary.word）当作个人生僻字。

只读：按文件修改时间缓存，生字本变了下一屏重读。返回的集合含原词（英文另存小写）与词里每个非 ASCII 字，
注音层把它们当作「不看阈值」的词：词库里有读音就注。

@module koplugin.book.features.rare.vocab
--]]

local logger = require("utils.log")

local Vocab = {}

local cache_mtime, cache_set

--- 生字本数据库路径。
---@return string
function Vocab.path()
    return require("datastorage"):getSettingsDir() .. "/vocabulary_builder.sqlite3"
end

--- 词表 → 集合：词本身、小写、每个非 ASCII 字。纯函数。
---@param words string[]
---@return table<string, boolean>
function Vocab.toSet(words)
    local set = {}
    for _idx, word in ipairs(words) do
        if type(word) == "string" and word ~= "" then
            set[word], set[word:lower()] = true, true
            for c in word:gmatch("[\194-\244][\128-\191]*") do set[c] = true end
        end
    end
    return set
end

--- 当前生字本集合；没有生字本 / 读失败返回空表。
---@return table<string, boolean>
function Vocab.set()
    local path = Vocab.path()
    local mtime = require("libs/libkoreader-lfs").attributes(path, "modification")
    if not mtime then return {} end
    if mtime == cache_mtime and cache_set then return cache_set end
    local words = {}
    local ok, err = pcall(function()
        local conn = require("lua-ljsqlite3/init").open(path)
        local rows = conn:exec("SELECT word FROM vocabulary")
        conn:close()
        for _idx, word in ipairs(rows and rows[1] or {}) do words[#words + 1] = tostring(word) end
    end)
    if not ok then
        logger.warn("book.rare vocab read failed", err)
        cache_mtime, cache_set = mtime, {}
        return cache_set
    end
    cache_mtime, cache_set = mtime, Vocab.toSet(words)
    return cache_set
end

return Vocab
