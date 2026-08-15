--[[--
按章阅读：在 ReaderUI 上最小 hook，把「翻到开头再向后翻」变成 StartOfBook。

仅当 chapters 会话 active 时生效。

@module koplugin.book.chapters.patches
--]]

local Event = require("ui/event")
local Session = require("chapters.session")

local Patches = {
    _enabled = false,
}

--- 给当前 ReaderUI 装滚动/分页边界检测。
---@param read_ui table|nil
function Patches.wrapReaderUi(read_ui)
    if not read_ui then
        return
    end
    local ui = read_ui.name == "ReaderUI" and read_ui or read_ui.ui
    if not ui or ui.name ~= "ReaderUI" then
        return
    end
    if ui._ref_book_chapters_wrapped then
        return
    end
    ui._ref_book_chapters_wrapped = true

    if ui.rolling and ui.rolling.onGotoViewRel then
        local orig = ui.rolling.onGotoViewRel
        ui.rolling.onGotoViewRel = function(self, diff)
            if not Patches._enabled or not Session.isActive() then
                return orig(self, diff)
            end
            local scroll_mode = self.view and self.view.view_mode == "scroll"
            local old_pos = scroll_mode and self.current_pos or self.current_page
            local ret = orig(self, diff)
            local new_pos = scroll_mode and self.current_pos or self.current_page
            if diff < 0 and old_pos == new_pos then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
            return ret
        end
    end

    if ui.paging and ui.paging.onGotoViewRel then
        local orig = ui.paging.onGotoViewRel
        ui.paging.onGotoViewRel = function(self, diff)
            if not Patches._enabled or not Session.isActive() then
                return orig(self, diff)
            end
            local old_pos = self.getTopPage and self:getTopPage() or self.current_page
            local ret = orig(self, diff)
            local new_pos = self.getTopPage and self:getTopPage() or self.current_page
            if diff < 0 and old_pos == 1 and old_pos == new_pos then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
            return ret
        end
    end
end

function Patches.enable()
    Patches._enabled = true
end

function Patches.disable()
    Patches._enabled = false
end

return Patches
