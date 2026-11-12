--[[--
书摘分享入口：经扩展点登记划词按钮和书摘列表动作；收集摘文时不保存划线。

@module tests.features.share.init_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path)
        return path == "/covers/sid.png" and "file" or nil
    end }
end
package.preload["utils.paths"] = function()
    return { coverPath = function(stable_id, source_id) return "/covers/" .. source_id .. ".png" end }
end
package.preload["utils.text"] = function()
    return { trim = function(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end }
end
package.preload["util"] = function()
    return { cleanupSelectedText = function(text) return text:gsub("%s+", "") end }
end
package.preload["reader.session"] = function()
    return {
        current = function()
            return {
                identity = {
                    source_id = "sid",
                    stable_id = "book1",
                    book = { title = "东坡乐府", authors = "苏轼" },
                },
            }
        end,
        chapterTitle = function() return "水调歌头" end,
    }
end

-- 先加载扩展点模块，避免 share init 登记到被其它测试留下的脏表（本进程独立）。
package.loaded["utils.extension"] = nil
local Ext = require("utils.extension")
Ext.reset()

package.loaded["features.share"] = nil
local Share = require("features.share")

-- 划词菜单按钮经 highlight.buttons 登记。
local buttons = Ext.list("highlight.buttons")
Assert.eq(#buttons, 1)
Assert.eq(buttons[1].key, "share")
local saved = 0
local closed = 0
local highlight = {
    selected_text = { text = "  明月几时有  " },
    onClose = function(self)
        closed = closed + 1
    end,
    saveHighlight = function() saved = saved + 1 end,
    ui = { doc_props = { display_title = "文档标题" } },
}
local opened
package.loaded["features.share.dialog"] = { open = function(payload) opened = payload end }
local button = buttons[1].factory(highlight, nil)
Assert.eq(button.text, "书摘")
button.callback()
Assert.eq(closed, 1, "关菜单")
Assert.eq(saved, 0, "分享不强制划线")
Assert.eq(opened.text, "明月几时有")
Assert.eq(opened.title, "东坡乐府")
Assert.eq(opened.authors, "苏轼")
Assert.eq(opened.chapter, "水调歌头")
Assert.eq(opened.cover, "/covers/sid.png")

-- 已有高亮：用注解正文和章节，仍不存新划线。
local highlight2 = {
    selected_text = { text = "选区" },
    ui = { annotation = { annotations = { { text = "又恐琼楼玉宇", chapter = "丙辰中秋" } } } },
    onClose = function() end,
    saveHighlight = function() saved = saved + 1 end,
}
local payload = Share.payloadFromHighlight(highlight2, 1)
Assert.eq(payload.text, "又恐琼楼玉宇")
Assert.eq(payload.chapter, "丙辰中秋")

-- 书摘列表动作。
local actions = Ext.list("note.item_actions")
Assert.eq(#actions, 1)
Assert.eq(actions[1].text, "书摘")
Assert.eq(actions[1].icon, "share")
opened = nil
actions[1].run({ text = "高处不胜寒。", chapter = "水调歌头" }, {})
Assert.eq(opened.text, "高处不胜寒。")
Assert.eq(opened.chapter, "水调歌头")
Assert.eq(opened.title, "东坡乐府")

-- 没有封面文件时不填封面路径。
package.loaded["utils.paths"] = {
    coverPath = function() return "/covers/missing.png" end,
}
-- coverOf 读的是 init 里已经 require 的 Paths，这里改 package.loaded 不会影响已绑定的模块。
-- 改用 payload：stable_id/source 仍走原 Paths。用一个不存在的身份即可。
-- Paths.coverPath 仍返回 /covers/sid.png（已存在）。另测 payloadFromNote 缺会话封面。
do
    local note = Share.payloadFromNote({ text = "一句" }, { snapshot = { identity = { source_id = "nope", stable_id = "x" } } })
    Assert.is_nil(note.cover)
    Assert.eq(note.text, "一句")
end

-- 空摘文仍能取出结构，交给 dialog 再提示。
local empty = Share.payloadFromHighlight({ selected_text = { text = "   " } }, nil)
Assert.eq(empty.text, "")

return true
