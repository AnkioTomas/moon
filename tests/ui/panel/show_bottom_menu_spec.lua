--[[-- 阅读菜单安装时保留用户已有的 show_bottom_menu 设置。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function() return { isTouchDevice = function() return true end } end
package.preload["ui/uimanager"] = function() return { show = function() end, setDirty = function() end } end
package.preload["ui.panel.native_settings"] = function() return { inject = function() end } end
package.preload["ui.panel.desktop"] = function() return { menuActions = function() return {} end } end
package.preload["ui.panel.reader"] = function() return { actions = function() return {} end } end
package.preload["ui/widget/touchmenu"] = function()
    return { updateItems = function() end, switchMenuTab = function() end }
end
package.preload["apps/filemanager/filemanagermenu"] = function()
    return { setUpdateItemTable = function() end }
end
package.preload["apps/reader/readerui"] = function() return { instance = nil } end
package.preload["apps/filemanager/filemanager"] = function() return { instance = nil } end

-- installReaderMenu 靠 ReaderMenu._book_reader_panel_patched 做一次性守卫，
-- 每次 install 必须换一张干净的 ReaderMenu，否则只有第一次真正跑到设置逻辑。
package.preload["apps/reader/modules/readermenu"] = function()
    return { setUpdateItemTable = function() end, getDefaultMenuButtons = function() return {} end }
end

local previous_settings = _G.G_reader_settings

---@param existing boolean|nil 用户已有的 show_bottom_menu
---@return table saved 本次 install 写入的设置
local function installWith(existing)
    local saved = {}
    _G.G_reader_settings = {
        readSetting = function(_, key)
            if key == "show_bottom_menu" then return existing end
            return nil
        end,
        saveSetting = function(_, key, value) saved[key] = value end,
    }
    package.loaded["ui.panel.native"] = nil
    package.loaded["apps/reader/modules/readermenu"] = nil
    require("ui.panel.native").install({}, { reader = true })
    return saved
end

-- 用户已显式设过（含显式 false）：install 不得覆盖
Assert.is_nil(installWith(true).show_bottom_menu, "已有 true 不得被覆盖")
Assert.is_nil(installWith(false).show_bottom_menu, "已有 false 不得被覆盖")

-- 正向控制：没设过时 install 必须写入 false，证明这段逻辑真的跑到了
-- （否则上面两条 nil 断言在 install 变成空实现时同样为真）
-- 必须 eq(false) 而非 is_false()：后者判 falsy，saveSetting 没被调用时的 nil 也会通过
Assert.eq(installWith(nil).show_bottom_menu, false, "未设置时应默认关闭底部菜单")

_G.G_reader_settings = previous_settings
