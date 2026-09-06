--[[-- X-Ray 刷新入口强制重新生成当前书籍数据。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(value) return value end }
end
package.preload["ui.components.popup"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end }
end
package.preload["utils.text"] = function() return {} end
package.preload["xray.kinds"] = function() return {} end
package.preload["db.xray"] = function() return {} end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ai"] = function()
    return { isConfigured = function() return true end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, callback) callback() end }
end

local identity = { source_id = "moon", stable_id = "book-1" }
package.preload["ui.reader.session"] = function()
    return { current = function() return { identity = identity } end }
end

local captured
package.preload["xray.fetch"] = function()
    return {
        comprehensive = function(ui, current, opts)
            captured = { ui = ui, identity = current, opts = opts }
        end,
    }
end

local ui = {}
require("xray.ui").refresh(ui)

Assert.eq(captured.ui, ui)
Assert.eq(captured.identity, identity)
Assert.is_true(captured.opts.force)

return true
