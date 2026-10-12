--[[-- X-Ray 刷新入口强制重新生成当前书籍数据。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(value) return value end }
end
package.preload["ui.themes.widgets.list"] = function() return {} end
local viewer
package.preload["ui.themes.widgets.text_viewer"] = function()
    return { new = function(_self, o)
        viewer = o
        o.show = function() o.shown = true end
        return o
    end }
end
package.preload["utils.text"] = function() return {} end
package.preload["features.xray.kinds"] = function() return { label = function() return "人物" end } end
package.preload["features.xray.db"] = function() return {} end
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_, opts)
        opts.show = function() end
        opts.close = function() end
        return opts
    end }
end
package.preload["ai"] = function()
    return { isConfigured = function() return true end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, callback) callback() end }
end

local identity = { source_id = "moon", stable_id = "book-1" }
package.preload["reader.session"] = function()
    return { current = function() return { identity = identity } end }
end

local captured
package.preload["features.xray.fetch"] = function()
    return {
        comprehensive = function(ui, current, opts)
            captured = { ui = ui, identity = current, opts = opts }
        end,
    }
end

local ui = {}
require("features.xray.ui").refresh(ui)

Assert.eq(captured.ui, ui)
Assert.eq(captured.identity, identity)
Assert.is_true(captured.opts.force)

-- 实体详情：居中弹窗卡片，不全屏。
require("features.xray.ui").showEntity({ kind = "character", name = "李善德", role = "主角" })
Assert.is_true(viewer.shown)
Assert.eq(viewer.title, "李善德")
Assert.is_false(viewer.fullscreen)

return true
