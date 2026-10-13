--[[-- reader.session.derived_note：衍生版判断、文字定位、两个方向的三方合并。 --]]
---@diagnostic disable: undefined-field, missing-fields, inject-field, need-check-nil, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
Stubs.reset()
package.preload["json"] = function() return require("support.json_stub") end
local JSON = require("support.json_stub")

local snapshot = {}
package.preload["book.note_db"] = function()
    return { get = function() return { payload = JSON.encode(snapshot) } end }
end
local sidecars = {}
package.preload["docsettings"] = function()
    return {
        open = function(_, path)
            local data = sidecars[path] or {}
            sidecars[path] = data
            return {
                readSetting = function(_, key) return data[key] end,
                saveSetting = function(_, key, value) data[key] = value end,
                flush = function() data.flushed = true end,
            }
        end,
    }
end
local saves = 0
package.preload["reader.session.note"] = function()
    return { save = function(_ui, _identity, done) saves = saves + 1; done(true) end }
end

local DerivedNote = require("reader.session.derived_note")
local Paths = require("utils.paths")

--- xpointer 写成 "/p[页].偏移"，按页 * 1000 + 偏移排先后。
local function order(xp)
    local page, offset = xp:match("^/p%[(%d+)%]%.(%d+)$")
    return tonumber(page) * 1000 + tonumber(offset)
end
local function document(file, hits)
    return {
        file = file,
        getPageCount = function() return 100 end,
        getPageFromXPointer = function(_, xp) return math.floor(order(xp) / 1000) end,
        compareXPointers = function(_, a, b)
            local x, y = order(a), order(b)
            return y > x and 1 or (y < x and -1 or 0)
        end,
        findAllText = function(_, pattern) return hits[pattern] end,
    }
end
local function reader(doc, annotations, settings)
    local ui = {
        document = doc,
        rolling = {},
        toc = { getTocTitleByPage = function() return "第一章" end },
        doc_settings = {
            readSetting = function(_, key) return settings[key] end,
            saveSetting = function(_, key, value) settings[key] = value end,
        },
        annotation = { annotations = annotations, updated = 0 },
    }
    function ui.annotation:addItem(item) table.insert(self.annotations, item) end
    function ui.annotation:updateAnnotations() self.updated = self.updated + 1 end
    return ui
end
local function datetimes(items)
    local list = {}
    for _idx, item in ipairs(items) do list[#list + 1] = item.datetime end
    table.sort(list)
    return table.concat(list, ",")
end

-- 定位：开头取离全书比例最近的命中；多行时结尾取开头之后最近的命中
do
    local doc = document("/x.epub", {
        ["月色"] = { { start = "/p[10].0", ["end"] = "/p[10].2" }, { start = "/p[80].5", ["end"] = "/p[80].7" } },
        ["他说今天"] = { { start = "/p[50].0", ["end"] = "/p[50].4" } },
        ["很好。"] = { { start = "/p[40].0", ["end"] = "/p[40].3" }, { start = "/p[51].1", ["end"] = "/p[51].4" },
            { start = "/p[60].0", ["end"] = "/p[60].3" } },
    })
    local pos0, pos1 = DerivedNote.locate(doc, " 月色 ", 0.75)
    Assert.eq(pos0, "/p[80].5")
    Assert.eq(pos1, "/p[80].7")
    pos0, pos1 = DerivedNote.locate(doc, "他说今天\n很好。", 0.5)
    Assert.eq(pos0, "/p[50].0")
    Assert.eq(pos1, "/p[51].4", "结尾必须在开头之后，取最近的")
    Assert.is_nil(DerivedNote.locate(doc, "不存在", 0.5))
    Assert.is_nil(DerivedNote.locate(doc, "他说今天\n没有结尾", 0.5), "结尾搜不到就算没找到")
    Assert.is_nil(DerivedNote.locate(doc, "  ", 0.5))
    Assert.eq(DerivedNote.locate(doc, "月色", nil), "/p[10].0", "比例未知取第一个命中")
end

local identity = { source_id = "local", stable_id = "/books/derived-note.epub" }
local root = Paths.bookWorkDir(identity.stable_id, identity.source_id)
require("ffi/util").purgeDir(root)
local origin = "/books/derived-note.epub"
local derived = root .. "/reflow/book.epub"
assert(Paths.ensureDir(root .. "/reflow"))
local f = assert(io.open(root .. "/reflow/meta.json", "wb"))
f:write(JSON.encode({ origin = origin, file = derived }))
f:close()
f = assert(io.open(derived, "wb"))
f:write("epub")
f:close()

-- 衍生版判断：同目录 meta.json 的 file 就是自己
Assert.eq(DerivedNote.originOf(derived), origin)
Assert.is_nil(DerivedNote.originOf(root .. "/reflow/other.epub"))
Assert.is_nil(DerivedNote.originOf(origin))

-- 读衍生版：原书新划线搜进来；原书删掉的跟着删；原书改过的盖过来；衍生版刚删、还没回原书的不复活
do
    snapshot = {
        { datetime = "new", drawer = "lighten", text = "月色", pageno = 80, total_pages = 100 },
        { datetime = "edited", drawer = "lighten", text = "旧", note = "原书改的", datetime_updated = "2026-02" },
        { datetime = "deleted-here", drawer = "lighten", text = "删" },
        { datetime = "bookmark", text = "书签", pageno = 3 },
        { datetime = "zero", drawer = "lighten", text = "月色", pageno = 80, total_pages = 0 },
    }
    local annotations = {
        { datetime = "edited", drawer = "lighten", text = "旧", note = "旧笔记", datetime_updated = "2026-01" },
        { datetime = "gone-at-origin", drawer = "lighten", text = "没了" },
        { datetime = "mine", drawer = "lighten", text = "衍生版自己的" },
    }
    local settings = { annotations = annotations,
        book_note_linked = { edited = true, ["gone-at-origin"] = true, ["deleted-here"] = true } }
    local ui = reader(document(derived, {
        ["月色"] = { { start = "/p[10].0", ["end"] = "/p[10].2" }, { start = "/p[78].0", ["end"] = "/p[78].2" } },
    }), annotations, settings)
    DerivedNote.project(ui, identity)
    Stubs.flush()
    Assert.eq(datetimes(annotations), "edited,mine,new,zero")
    Assert.eq(annotations[1].note, "原书改的")
    local placed = annotations[3]
    Assert.eq(placed.pos0, "/p[78].0")
    Assert.eq(annotations[4].pos0, "/p[10].0", "total_pages 为 0 不能拿页码当比例，退回第一个命中")
    Assert.eq(placed.page, "/p[78].0")
    Assert.eq(placed.chapter, "第一章")
    local linked = settings.book_note_linked
    Assert.is_true(linked.new)
    Assert.is_true(linked["deleted-here"], "等回原书时再删")
    Assert.is_nil(linked["gone-at-origin"])
    Assert.is_nil(linked.bookmark, "书签不跨版本")
    Assert.is_true(ui.annotation.updated > 0)
end

-- 读原书：衍生版新划线收进原书（搜不到的记 false 不再重搜），衍生版删改的同步过来，然后存快照
do
    sidecars[derived] = {
        doc_pages = 200,
        annotations = {
            { datetime = "fresh", drawer = "lighten", text = "月色", pageno = 20 },
            { datetime = "translated", drawer = "lighten", text = "moonlight" },
            { datetime = "edited", drawer = "lighten", text = "旧", note = "衍生版改的", datetime_updated = "2026-03" },
        },
        book_note_linked = { edited = true, removed = true, skipped = false },
    }
    local annotations = {
        { datetime = "edited", drawer = "lighten", text = "旧", note = "原书的", datetime_updated = "2026-02" },
        { datetime = "removed", drawer = "lighten", text = "衍生版删了" },
        { datetime = "own", drawer = "lighten", text = "原书自己的" },
    }
    local ui = reader(document(origin, {
        ["月色"] = { { start = "/p[10].0", ["end"] = "/p[10].2" }, { start = "/p[90].0", ["end"] = "/p[90].2" } },
    }), annotations, {})
    saves = 0
    DerivedNote.collect(ui, identity)
    Stubs.flush()
    Assert.eq(datetimes(annotations), "edited,fresh,own")
    Assert.eq(annotations[1].note, "衍生版改的")
    Assert.eq(annotations[3].pos0, "/p[10].0", "20/200 离第 10 页最近")
    Assert.eq(saves, 1)
    local linked = sidecars[derived].book_note_linked
    Assert.is_true(linked.fresh)
    Assert.eq(linked.translated, false)
    Assert.is_nil(linked.removed)
    Assert.eq(linked.skipped, false)
    Assert.is_true(sidecars[derived].flushed)

    -- 再来一次没有变化：不重搜、不存
    saves = 0
    DerivedNote.collect(ui, identity)
    Stubs.flush()
    Assert.eq(saves, 0)

    -- PDF 原书搜不出 xpointer：不收
    sidecars[derived].annotations[#sidecars[derived].annotations + 1] =
        { datetime = "later", drawer = "lighten", text = "月色" }
    ui.rolling = nil
    DerivedNote.collect(ui, identity)
    Stubs.flush()
    Assert.eq(saves, 0)
end

require("ffi/util").purgeDir(root)
