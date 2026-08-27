--[[--
book.reader_prefs 离线用例：捕获、落库与应用。

@module tests.book.reader_prefs_spec
--]]

local Assert = require("support.assert")

local saved_payload
package.preload["utils.db.book"] = function()
    return {
        getReaderPrefs = function(source_id, stable_id)
            Assert.eq(source_id, "moon")
            Assert.eq(stable_id, "book-1")
            return saved_payload
        end,
        setReaderPrefs = function(source_id, stable_id, payload)
            Assert.eq(source_id, "moon")
            Assert.eq(stable_id, "book-1")
            saved_payload = payload
            return true
        end,
    }
end

package.preload["book.store"] = function()
    return {
        ensureIdentity = function()
            return { source_id = "moon", stable_id = "book-1" }
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = function(value)
            return require("ffi/util").serialize(value)
        end,
        decode = function(raw)
            if type(raw) ~= "string" or raw == "" then return nil end
            local fn = loadstring("return " .. raw)
            if not fn then return nil end
            local ok, value = pcall(fn)
            return ok and value or nil
        end,
    }
end

package.preload["utils.font"] = function()
    return {
        supportsReader = function(ui)
            return ui and ui.font ~= nil and ui.document and ui.document.setFontFace
        end,
        applyToReader = function() return true end,
    }
end

package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ffi/util"] = function()
    return {
        serialize = function(value)
            local seen = {}
            local function dump(v, depth)
                depth = depth or 0
                local t = type(v)
                if t == "number" then return tostring(v) end
                if t == "string" then return string.format("%q", v) end
                if t ~= "table" then return "nil" end
                if seen[v] then return "nil" end
                seen[v] = true
                local parts, n = {}, 0
                for i = 1, #v do
                    n = n + 1
                    parts[n] = dump(v[i], depth + 1)
                end
                for k, val in pairs(v) do
                    if type(k) == "string" then
                        n = n + 1
                        parts[n] = k .. "=" .. dump(val, depth + 1)
                    end
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
            return dump(value)
        end,
    }
end

package.loaded["book.reader_prefs"] = nil
package.loaded["json"] = nil
package.loaded["ffi/util"] = nil
package.loaded["utils.font"] = nil
package.loaded["utils.db.book"] = nil
package.loaded["book.store"] = nil
local ReaderPrefs = require("book.reader_prefs")

local ui = {
    font = {
        onSetFont = function() end,
        onSaveSettings = function() end,
        onSetFontSize = function() end,
        onSetLineSpace = function() end,
    },
    document = {
        setFontFace = function() end,
        configurable = {
            h_page_margins = { 5, 5 },
            t_page_margin = 10,
            b_page_margin = 12,
            sync_t_b_page_margins = 0,
            font_size = 22,
            line_spacing = 100,
            saveSettings = function() end,
        },
    },
    doc_settings = {
        data = {},
        saveSetting = function(self, key, value) self.data[key] = value end,
        readSetting = function(self, key) return self.data[key] end,
        flush = function() end,
    },
    typeset = {
        onSetPageHorizMargins = function() end,
        onSetPageTopAndBottomMargin = function() end,
    },
    handleEvent = function() end,
    dialog = {},
}

local identity = { source_id = "moon", stable_id = "book-1" }

ui.doc_settings.data.book_reader_font_id = "demo.ttf"
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
Assert.is_true(type(saved_payload) == "string" and #saved_payload > 0)

saved_payload = nil
Assert.is_false(ReaderPrefs.apply(ui, identity))

ui.document.configurable.h_page_margins = { 40, 40 }
Assert.is_true(ReaderPrefs.captureAndSave(ui, identity))
local loaded = ReaderPrefs.load(identity)
Assert.eq(loaded.font_id, "demo.ttf")
Assert.eq(loaded.copt.h_page_margins[1], 40)
Assert.is_true(ReaderPrefs.apply(ui, identity))

return true
