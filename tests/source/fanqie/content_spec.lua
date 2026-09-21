--[[--
番茄 PUA 解码：真实章节片段必须解成可读中文。

@module tests.source.fanqie.content_spec
--]]

local Assert = require("support.assert")

package.loaded["source.fanqie.content"] = nil
local Content = require("source.fanqie.content")

-- /api/reader/full 第1章首段原始字节（含 PUA）
local sample = "\227\128\144\238\144\178\232\176\162\230\130\168\238\146\168\229\135\187\238\147\184\238\147\186\233\152\133\232\175\187\239\188\140\238\147\175\238\146\142\238\147\179\238\147\131\238\148\170\238\145\138\238\144\182\239\188\140\231\174\128\228\187\139\238\145\141\238\144\142\238\146\128\227\128\145"
local decoded = Content.decode_pua_content(sample)
Assert.eq(decoded, "【感谢您点击进来阅读，其他的就不说了，简介里都有】")
