--[[--
系统输入法快照协议：dex 侧写文件、Lua 侧解析。覆盖 CH / BS / ST、base64、
UTF-16 光标换算与长文本 / 表情不丢字。

@module tests.features.system_ime.snapshot_spec
--]]

local Assert = require("support.assert")
local Snapshot = require("features.system_ime.snapshot")

-- ── base64：dex 用 NO_WRAP 输出 UTF-8 文本 ─────────────
Assert.eq(Snapshot.decodeBase64("5L2g5aW9"), "你好", "UTF-8 中文")
Assert.eq(Snapshot.decodeBase64("aGVsbG8="), "hello", "带 padding")
Assert.eq(Snapshot.decodeBase64("YQ=="), "a", "单字节")
Assert.eq(Snapshot.decodeBase64("8J+YgA=="), "😀", "四字节表情")
Assert.eq(Snapshot.decodeBase64(""), "", "空串")
Assert.is_nil(Snapshot.decodeBase64(nil), "非字符串返回 nil")

-- ── 解析：dex 快照一行一个动作 ───────────────────────
local actions = Snapshot.parse(table.concat({
    "CH:hello",
    "BS",
    "ST:1:2:aGk=",
    "",
}, "\r\n"))
Assert.len(actions, 3, "空行忽略，CRLF 兼容")
Assert.eq(actions[1].type, "chars")
Assert.eq(actions[1].text, "hello")
Assert.eq(actions[2].type, "backspace")
Assert.eq(actions[3].type, "state")
Assert.eq(actions[3].text, "hi")
Assert.eq(actions[3].sel_start, 1)
Assert.eq(actions[3].sel_end, 2)

-- 坏行跳过，不让一次脏快照打断轮询
Assert.len(Snapshot.parse("ST:bad\ngarbage\nST:0:0:5L2g5aW9"), 1)

-- ── UTF-16 光标：Java 的 offset 按 code unit，Lua 按字符 ─
Assert.eq(Snapshot.utf16Length("abc", 2), 2, "ASCII 一对一")
Assert.eq(Snapshot.utf16Length("a😀b", 2), 3, "表情占两个 code unit")

Assert.eq(Snapshot.charPosFromUtf16("abc", 2), 3, "ASCII 光标")
Assert.eq(Snapshot.charPosFromUtf16("a😀b", 0), 1)
Assert.eq(Snapshot.charPosFromUtf16("a😀b", 1), 2, "表情之前")
Assert.eq(Snapshot.charPosFromUtf16("a😀b", 2), 2, "落在代理对中间 → 表情之前")
Assert.eq(Snapshot.charPosFromUtf16("a😀b", 3), 3, "表情之后")
Assert.eq(Snapshot.charPosFromUtf16("a😀b", 4), 4, "结尾")
Assert.eq(Snapshot.charPosFromUtf16("a😀b", 99), 4, "越界夹到结尾")
