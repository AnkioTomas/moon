--[[--
书摘编辑入口：空摘文提示，有摘文时打开编辑页并记住上次选项。

@module tests.features.share.dialog_spec
--]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["utils.text"] = function()
    return { trim = function(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end }
end

Themed.install()

local Paths = require("utils.paths")
os.remove(Paths.sectionPath("share"))
package.loaded["utils.settings"] = nil
package.loaded["features.share.settings"] = nil
package.loaded["features.share.setting"] = nil

local opened
package.preload["features.share.editor"] = function()
    return {
        mergeState = function(state)
            state = state or {}
            return {
                theme = state.theme or "calendar",
                font = state.font or "song",
                font_id = state.font_id,
                font_name = state.font_name,
                swatch = state.swatch or "default",
                art = state.art,
                show_logo = state.show_logo ~= false,
            }
        end,
        new = function(_, opts)
            opts = opts or {}
            opts.show = function(self)
                self.shown = true
                opened = self
                return self
            end
            opts.close = function(self)
                self.closed = true
                if self.close_callback then self.close_callback() end
            end
            return opts
        end,
    }
end

package.loaded["features.share.dialog"] = nil
local Dialog = require("features.share.dialog")

Dialog.open({ text = "   " })
Assert.is_nil(opened, "空摘文不打开编辑页")
local toast = Themed.last("toast")
Assert.not_nil(toast)
Assert.eq(toast.text, "没有可摘录的文字")

Dialog.open({ text = "  明月几时有  ", title = "东坡乐府" })
Assert.not_nil(opened)
Assert.is_true(opened.shown)
Assert.eq(opened.payload.text, "明月几时有")
Assert.eq(opened.payload.title, "东坡乐府")
Assert.eq(opened.state.theme, "calendar")
Assert.eq(opened.state.show_logo, true)

opened.state.theme = "scenic"
opened.state.art = "window"
opened.state.show_logo = false
opened.state.font_id = "KingHwa_OldSong"
opened.state.font_name = "京华老宋体"
opened.state.show_logo = false
opened:close()
Assert.eq(Dialog.last.theme, "scenic")
Assert.eq(Dialog.last.art, "window")
Assert.is_false(Dialog.last.show_logo)
Assert.eq(Dialog.last.font_id, "KingHwa_OldSong")
Assert.is_false(Dialog.last.show_logo)

-- 丢掉进程内配置缓存，模拟下次打开。
package.loaded["utils.settings"] = nil
package.loaded["features.share.settings"] = nil
package.loaded["features.share.setting"] = nil
opened = nil
Dialog.open({ text = "高处不胜寒。" })
Assert.eq(opened.state.theme, "scenic")
Assert.eq(opened.state.art, "window")
Assert.is_false(opened.state.show_logo)
Assert.eq(opened.state.font_id, "KingHwa_OldSong")
Assert.eq(opened.state.font_name, "京华老宋体")
Assert.is_false(opened.state.show_logo)

os.remove(Paths.sectionPath("share"))
return true
