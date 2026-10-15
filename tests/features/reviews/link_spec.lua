--[[-- features.reviews.link：哪些书能关联书城版。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.preload["ui.themes.widgets.toast"] = function() return {} end
package.preload["l10n"] = function() return { apply = function() end } end

local identity
local real_session = package.loaded["reader.session"]
package.loaded["reader.session"] = { current = function() return identity and { identity = identity } end }
local Link = require("features.reviews.link")
local ui = { document = { getPageXPointer = function() end, findText = function() end } }

identity = { source_id = "wechat", stable_id = "CB_9", chapter_idx = 1 }
Assert.is_true(Link.available(ui), "微信读书的书放开（上传书借正版段评）")
identity = { source_id = "jdread", stable_id = "30", chapter_idx = 1 }
Assert.is_true(Link.available(ui), "京东读书可关联")
identity = { source_id = "local", stable_id = "/a.epub" }
Assert.is_true(Link.available(ui))
Assert.is_false(Link.available({ document = { getPageXPointer = function() end } }), "PDF 不行")
identity = nil
Assert.is_false(Link.available(ui))
package.loaded["reader.session"] = real_session
