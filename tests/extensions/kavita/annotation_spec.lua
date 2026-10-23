--[[--
extensions/moonsource-kavita.koplugin：注解线上形态（写入 / 读回）与同一性键。

备注在 Kavita 侧是 Quill Delta JSON（`comment`）+ Quill HTML（`commentHtml`），
纯文本 `commentPlainText` 由后端从 HTML 去标签算出来。拉取、推送、冲突判定必须
共用这一套归一，否则同一段备注每次都会判「改过」→ 无限 update。

@module tests.extensions.kavita.annotation_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local JsonStub = require("support.json_stub")

-- 模块内部 require("json")；这里给真实语义的往返桩（encode 出的串 decode 得回同一结构）。
package.loaded["json"] = { encode = JsonStub.encode, decode = JsonStub.decode }

local Annotation = dofile(Config.root() .. "/extensions/moonsource-kavita.koplugin/moonsource_kavita/annotation.lua")

-- 读回：空值集合一律空串（漏判的后果不是显示花括号，而是 note 变成 "{}" → 无限 update）。
Assert.eq(Annotation.noteText(nil), "")
Assert.eq(Annotation.noteText(""), "")
Assert.eq(Annotation.noteText("   "), "")
Assert.eq(Annotation.noteText("{}"), "")
Assert.eq(Annotation.noteText('{"ops":[]}'), "")
Assert.eq(Annotation.noteText('{"ops":[{"insert":"\\n"}]}'), "")
Assert.eq(Annotation.noteText('{"ops":[{"insert":"   \\n"}]}'), "", "只含空白 insert 也是空")
Assert.eq(Annotation.noteText("null"), "")

-- Delta：拼接字符串 insert，跳过 embed，忽略 attributes，剥掉末尾换行。
Assert.eq(Annotation.noteText('{"ops":[{"insert":"一句话\\n"}]}'), "一句话")
Assert.eq(
    Annotation.noteText('{"ops":[{"insert":"第一行\\n"},{"insert":"第二行","attributes":{"bold":true}},{"insert":"\\n"}]}'),
    "第一行\n第二行"
)
Assert.eq(
    Annotation.noteText('{"ops":[{"insert":"有图\\n"},{"insert":{"image":"x.png"}},{"insert":"\\n"}]}'),
    "有图",
    "非字符串 insert（图片等 embed）跳过"
)
Assert.eq(Annotation.noteText('{"ops":[{"insert":"a\\nb\\n"}]}'), "a\nb", "文内换行原样保留")

-- 非 JSON 的 legacy 纯文本：原样返回（不能当空，也不能当 Delta 报错）。
Assert.eq(Annotation.noteText("存量纯文本备注"), "存量纯文本备注")

-- 优先级：commentHtml → commentPlainText → 解析 comment。
Assert.eq(Annotation.noteText('{"ops":[{"insert":"delta\\n"}]}', "<p>html</p>", "plain"), "html")
Assert.eq(Annotation.noteText('{"ops":[{"insert":"delta\\n"}]}', "", "plain"), "plain")
Assert.eq(Annotation.noteText('{"ops":[{"insert":"delta\\n"}]}', "  ", " "), "delta")

-- commentHtml：块级边界转换行（后端 StripHtml 不插分隔，块之间会粘）。
Assert.eq(Annotation.noteText(nil, "<p>第一段</p><p>第二段</p>", ""), "第一段\n第二段")
Assert.eq(Annotation.noteText(nil, "<p>a<br>b</p>", ""), "a\nb")
Assert.eq(Annotation.noteText(nil, "<p>a</p><p><br></p><p>b</p>", ""), "a\n\nb", "Quill 空行")
Assert.eq(Annotation.noteText(nil, "<div>a</div><div>b</div>", ""), "a\nb")
Assert.eq(Annotation.noteText(nil, "<p>a &amp; b &lt;c&gt; &quot;d&quot;</p>", ""), 'a & b <c> "d"', "实体解码")
Assert.eq(Annotation.noteText(nil, "<p><br></p>", ""), "", "全删后的空 HTML 也是空")

-- 写入：空备注与 Web「新建未输入」字节一致（"{}" + ""），不能写 {"ops":[...]}。
for _idx, note in ipairs({ nil, "", "   ", "\n\n", " \n \n" }) do
    local remote = Annotation.toRemote(note)
    Assert.eq(remote.comment, "{}", "空备注 comment")
    Assert.eq(remote.commentHtml, "", "空备注 commentHtml")
end

-- 写入：单个 insert op、末尾补 \n（Delta 文档必须以换行结尾）；每行一个 <p>。
local one = Annotation.toRemote("第一行\n第二行")
local ops = JsonStub.decode(one.comment).ops
Assert.eq(#ops, 1, "只有一个 insert op")
Assert.eq(ops[1].insert, "第一行\n第二行\n")
Assert.eq(one.commentHtml, "<p>第一行</p><p>第二行</p>", "空行写 <p><br></p>")
Assert.eq(Annotation.toRemote("a\n\nb").commentHtml, "<p>a</p><p><br></p><p>b</p>")

-- 写入：转义 & < > "；先转 & 再转别的，避免二次转义。
Assert.eq(
    Annotation.toRemote('a & b < c > d "e"').commentHtml,
    "<p>a &amp; b &lt; c &gt; d &quot;e&quot;</p>"
)

-- 写入：CRLF 归一、尾部换行去掉（否则每轮读回都多一行 → 判改过）。
local crlf = Annotation.toRemote("a\r\nb\n\n")
Assert.eq(JsonStub.decode(crlf.comment).ops[1].insert, "a\nb\n")
Assert.eq(crlf.commentHtml, "<p>a</p><p>b</p>")

-- 往返：自己写的备注读回后与归一后的 note 一致（push / pull 同一口径 → 零 update）。
for _idx, note in ipairs({
    "一句话",
    "第一行\n第二行",
    "a\n\nb",
    '引号 " 与反斜杠 \\ 都原样',
    "小于 < 大于 > 和 & 号",
    "好书📚 与 emoji 👍🏽",
    "  行首缩进保留",
}) do
    local remote = Annotation.toRemote(note)
    Assert.eq(Annotation.noteText(remote.comment), note, "Delta 读回：" .. note)
    Assert.eq(
        Annotation.noteText(remote.comment, remote.commentHtml, ""),
        note,
        "完整 DTO 读回（commentHtml 优先）：" .. note
    )
end

-- 比较归一：trim + 内部连续空白压一个 + 零宽剔除；两边都空判等。
Assert.is_true(Annotation.sameNote(nil, ""))
Assert.is_true(Annotation.sameNote("", "   "))
Assert.is_true(Annotation.sameNote("a  b", " a b "))
Assert.is_true(Annotation.sameNote("a\nb", "a b"), "换行也是空白")
Assert.is_true(Annotation.sameNote("a\226\128\139b", "ab"), "零宽空格剔除")
Assert.is_true(Annotation.sameNote("a\239\187\191b", "ab"), "BOM 剔除")
Assert.is_false(Annotation.sameNote("a", "b"))
Assert.is_false(Annotation.sameNote("", "a"))

-- 幂等键：comment 不参与、selectedText 空白归一、xPath 精确。
local base = { chapterId = 7, xPath = "//body/p[1]", endingXPath = "//body/p[2]", selectedText = "选中 文本" }
local function keyOf(over)
    local ann = {}
    for k, v in pairs(base) do ann[k] = v end
    for k, v in pairs(over or {}) do ann[k] = v end
    return Annotation.key(ann)
end
Assert.eq(keyOf({ comment = "甲" }), keyOf({ comment = "乙" }), "改备注不是新建")
Assert.eq(keyOf({ selectedText = " 选中\n文本 " }), keyOf({}), "选中文本的空白差异命中")
Assert.is_true(keyOf({ xPath = "//body/p[9]" }) ~= keyOf({}))
Assert.is_true(keyOf({ endingXPath = "//body/p[9]" }) ~= keyOf({}))
Assert.is_true(keyOf({ chapterId = 8 }) ~= keyOf({}))
Assert.eq(keyOf({}), "7" .. string.char(31) .. "//body/p[1]" .. string.char(31) .. "//body/p[2]" .. string.char(31) .. "选中 文本")
-- pull 落库后的本地条目把选中文本叫 text。
Assert.eq(
    Annotation.key({ chapterId = 7, xPath = "//body/p[1]", endingXPath = "//body/p[2]", text = "选中  文本" }),
    keyOf({})
)

-- 对账命中：同键多条取 id 最小；无命中 nil。
local remote = {
    { id = 9, chapterId = 7, xPath = "//body/p[1]", endingXPath = "//body/p[2]", selectedText = "选中 文本", comment = "{}" },
    { id = 3, chapterId = 7, xPath = "//body/p[1]", endingXPath = "//body/p[2]", selectedText = " 选中\n文本 ", comment = "{ops}" },
    { id = 1, chapterId = 7, xPath = "//body/p[5]", endingXPath = "//body/p[6]", selectedText = "别的划线" },
}
Assert.eq(Annotation.match(remote, base).id, 3, "同键两条取 id 最小")
Assert.eq(Annotation.match({ { id = "12", chapterId = 7, xPath = "//body/p[1]", endingXPath = "//body/p[2]", selectedText = "选中 文本" } }, base).id, "12", "字符串 id 也能比")
Assert.is_nil(Annotation.match(remote, { chapterId = 7, xPath = "//body/p[7]", endingXPath = "//body/p[8]", selectedText = "x" }))
Assert.is_nil(Annotation.match(nil, base))

-- 列表：`GET /api/Annotation/all?chapterId=`，无分页；owner_id 非空才按 ownerUserId 过滤
-- （owner_id 为空是 `/api/Users/me` 不可用时的降级：不过滤，宁可多看到自己的）。
local chapter = {
    { id = 1, ownerUserId = 5, comment = "{}" },
    { id = 2, ownerUserId = 9, comment = "别人的纯文本备注" },
    { id = 3, ownerUserId = 5, comment = "" },
}
local calls = {}
local function clientReturning(data, err)
    return {
        json = function(_self, method, path, query, body, cb)
            calls[#calls + 1] = { method = method, path = path, query = query, body = body }
            cb(data, err)
            return { cancel = function() end }
        end,
    }
end

local got, got_err
Annotation.listByChapter(clientReturning(chapter), 12763, nil, function(list, err) got, got_err = list, err end)
Assert.eq(calls[1].method, "GET")
Assert.eq(calls[1].path, "/api/Annotation/all")
Assert.eq(calls[1].query.chapterId, 12763)
Assert.is_nil(calls[1].query.pageNumber, "该接口没有分页")
Assert.is_nil(calls[1].body)
Assert.eq(#got, 3, "owner_id 为空时不过滤")
Assert.is_nil(got_err)

calls = {}
Annotation.listByChapter(clientReturning(chapter), 12763, 5, function(list) got = list end)
Assert.eq(#got, 2, "只留自己的注解")
Assert.eq(got[1].id, 1)
Assert.eq(got[2].id, 3)

calls = {}
Annotation.listByChapter(clientReturning(chapter), 12763, "5", function(list) got = list end)
Assert.eq(#got, 2, "字符串 owner_id 也能对上数字 ownerUserId")

Annotation.listByChapter(clientReturning(nil, "请求失败 (HTTP 400)"), 12763, 5, function(list, err)
    got, got_err = list, err
end)
Assert.is_nil(got, "失败回 nil")
Assert.eq(got_err, "请求失败 (HTTP 400)")

Annotation.listByChapter(clientReturning({}), 12763, 5, function(list) got = list end)
Assert.eq(#got, 0, "该章没有注解 = 空列表，不是 nil")
