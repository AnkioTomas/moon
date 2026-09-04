-- Target file to enable page turn animation for PDFs/CBZs in KOReader paged mode.
-- Upstream only emits PageChangeAnimation from ReaderRolling, so we emit it
-- here as well for paged documents.
--
-- Adapted from Swipe_Animation.koplugin (GPLv3).

local ok, err = pcall(function()
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    local Event = require("ui/event")

    if ReaderPaging._swipe_animation_pdf_patch_applied then
        return
    end
    ReaderPaging._swipe_animation_pdf_patch_applied = true

    local original_gotoPage = ReaderPaging._gotoPage

    --- 分页文档跳页前补发 PageChangeAnimation 事件（上游只在 ReaderRolling 发）。
    --- 只在真正翻页且非滚动模式、且开了动画开关时发；随后照常走原逻辑。
    ---@param number number 目标页码
    ---@param orig_mode any 透传给原方法
    function ReaderPaging:_gotoPage(number, orig_mode)
        -- Check if we are turning a page and not in scroll mode
        if self.current_page and self.current_page > 0 and number ~= self.current_page and not self.view.page_scroll then
            if G_reader_settings:isTrue("swipe_animations") then
                local forward = number > self.current_page
                self.ui:handleEvent(Event:new("PageChangeAnimation", forward))
            end
        end
        -- Call the original page turn logic
        return original_gotoPage(self, number, orig_mode)
    end
end)

if not ok then
    require("utils.log").warn("[PdfSwipeAnimationPatch] failed:", err)
end
