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
package.preload["utils.text"] = function()
    return { trim = function(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end }
end
package.preload["features.xray.kinds"] = function() return { label = function() return "人物" end } end
package.preload["features.xray.db"] = function() return {} end
local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_, opts)
        opts.show = function() toasts[#toasts + 1] = opts.text end
        opts.close = function() end
        return opts
    end }
end
local dialogs = {}
package.preload["ui.themes.widgets.progress_dialog"] = function()
    return { new = function(_, opts)
        opts.show = function() dialogs[#dialogs + 1] = opts end
        opts.close = function() opts.closed = true end
        return opts
    end }
end
local configured = true
package.preload["ai"] = function()
    return { isConfigured = function() return configured end }
end
local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local identity = { source_id = "moon", stable_id = "book-1" }
package.preload["reader.session"] = function()
    return { current = function() return { identity = identity } end }
end

local captured
local local_entities = {}
local looked_up
package.preload["features.xray.fetch"] = function()
    return {
        comprehensive = function(ui, current, opts)
            captured = { ui = ui, identity = current, opts = opts }
        end,
        findLocal = function(current, word)
            Assert.eq(current, identity)
            return local_entities[word]
        end,
        lookupWord = function(ui, current, word)
            looked_up = word
        end,
    }
end

local ui = {}
require("features.xray.ui").refresh(ui)

Assert.eq(captured.ui, ui)
Assert.eq(captured.identity, identity)
Assert.is_true(captured.opts.force)
Assert.eq(dialogs[#dialogs].text, "正在重新生成 X-Ray…")
Assert.eq(dialogs[#dialogs].dismissable, false, "生成中不可取消")
Assert.is_nil(dialogs[#dialogs].on_cancel)

-- 离线：立即提示，不拉取。
captured, connected = nil, false
require("features.xray.ui").refresh(ui)
Assert.is_nil(captured)
Assert.eq(toasts[#toasts], "网络不可用，请先连接 Wi-Fi")
connected = true

-- 实体详情：居中弹窗卡片，不全屏。
require("features.xray.ui").showEntity({ kind = "character", name = "李善德", role = "主角" })
Assert.is_true(viewer.shown)
Assert.eq(viewer.title, "李善德")
Assert.is_false(viewer.fullscreen)

-- 划词查：本地已收录的直接出详情，离线、未配置 AI 也行，不走 AI
local_entities["翠翠"] = { kind = "character", name = "翠翠", role = "主角" }
connected, configured = false, false
require("features.xray.ui").lookup(ui, " 翠翠 ")
Assert.eq(viewer.title, "翠翠")
Assert.is_nil(looked_up)

-- 没收录：离线时提示网络，联网才交给 AI
configured = true
require("features.xray.ui").lookup(ui, "爷爷")
Assert.is_nil(looked_up)
Assert.eq(toasts[#toasts], "网络不可用，请先连接 Wi-Fi")
connected = true
require("features.xray.ui").lookup(ui, "爷爷")
Assert.eq(looked_up, "爷爷")

return true
