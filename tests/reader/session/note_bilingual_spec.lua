--[[-- reader.session.note：双语章的划线退回原文、同章各版本 sidecar 互相镜像。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local sidecars = {}
package.preload["docsettings"] = function()
    return { open = function(_, file)
        return {
            saveSetting = function(_, key, value) sidecars[file] = sidecars[file] or {}; sidecars[file][key] = value end,
            flush = function() end,
        }
    end }
end
local stored
package.preload["book.note_db"] = function()
    return { get = function() return nil end, upsert = function(_, _, _, payload) stored = payload return true end }
end
package.preload["book.store"] = function() return {} end
package.preload["json"] = function() return require("support.json_stub") end
package.loaded["json"] = nil

local Paths = require("utils.paths")
local SessionNote = require("reader.session.note")

local P = "/body/DocFragment/body/p[2]"
local SPAN = P .. "/span"
local END = P .. "/text().5" -- 译文前最后一个字之后：原章里也存在
local document = {
    getHTMLFromXPointer = function(_, xp)
        if xp == SPAN then return '<span class="moon-tr" style="display:block">你好</span>' end
        return "<p>Hello</p>"
    end,
    getPrevVisibleChar = function(_, xp)
        if xp == SPAN then return P .. "/text().4" end
    end,
    getTextFromXPointers = function(_, a, b)
        if a == P and b == END then return " Hello " end
        return "?"
    end,
}

-- 整段落在译文里：退成整段原文；起点在原文、终点在译文：终点退到译文前；不在译文的不动。
local items = {
    { pos0 = SPAN .. "/text().0", pos1 = SPAN .. "/text().2", text = "你好", drawer = "lighten" },
    { pos0 = P .. "/text().0", pos1 = SPAN .. "/text().1", text = "Hello 你", drawer = "lighten" },
    { pos0 = P .. "/text().1", pos1 = P .. "/text().3", text = "ell", drawer = "lighten" },
}
SessionNote._untranslate(document, items)
Assert.eq(items[1].pos0, P)
Assert.eq(items[1].pos1, END)
Assert.eq(items[1].text, "Hello")
Assert.eq(items[1].page, P)
Assert.eq(items[2].pos0, P .. "/text().0")
Assert.eq(items[2].pos1, END)
Assert.eq(items[3].pos0, P .. "/text().1")
Assert.eq(items[3].text, "ell")

-- 存双语章：注解先退回原文，再镜像到原章和别的双语章；存原章也镜像到双语章。
local identity = { source_id = "wechat", stable_id = "note-bi-spec", chapter_idx = 4 }
local work = Paths.bookWorkDir(identity.stable_id, identity.source_id)
assert(Paths.ensureDir(work))
local origin = Paths.chapterPath(identity.stable_id, 4, identity.source_id)
local bi = Paths.bilingualChapterPath(origin, "edge-en")
local bi_ai = Paths.bilingualChapterPath(origin, "ai-en")
for _idx, file in ipairs({ origin, bi, bi_ai, Paths.chapterPath(identity.stable_id, 40, identity.source_id) }) do
    local f = assert(io.open(file, "wb")); f:write("<html/>"); f:close()
end
Assert.eq(#Paths.chapterVariants(bi), 2, "原章 + 另一双语章，不含 40 章")

local annotations = { { pos0 = SPAN .. "/text().0", pos1 = SPAN .. "/text().2", text = "你好", drawer = "lighten",
    datetime = "2026-10-16 13:00:00" } }
local doc_sidecar = {}
local ui = {
    document = setmetatable({ file = bi, getPageCount = function() return 10 end }, { __index = document }),
    annotation = { annotations = annotations },
    doc_settings = {
        flush = function() end,
        saveSetting = function(_, k, v) doc_sidecar[k] = v end,
        readSetting = function(_, k) return doc_sidecar[k] end,
    },
}
SessionNote.save(ui, identity)
Assert.eq(annotations[1].pos0, P, "落库前已退回原文")
Assert.eq(doc_sidecar.annotations, annotations)
Assert.eq(sidecars[origin].annotations[1].pos1, END)
Assert.not_nil(sidecars[bi_ai])
Assert.is_nil(sidecars[bi])
Assert.not_nil(stored)

-- 在原章上删光：双语章 sidecar 跟着变空，删除不会从另一版复活。
sidecars = {}
ui.document = setmetatable({ file = origin, getPageCount = function() return 10 end }, { __index = document })
ui.annotation.annotations = {}
SessionNote.save(ui, identity)
Assert.eq(#sidecars[bi].annotations, 0)
Assert.eq(#sidecars[bi_ai].annotations, 0)
require("ffi/util").purgeDir(work)
