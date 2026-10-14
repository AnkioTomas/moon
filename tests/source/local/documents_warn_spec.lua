--[[--
source.local.setting.isKindleDocuments：选 Kindle 的 documents 目录时要先提醒。

@module tests.source.local.documents_warn_spec
--]]

local Assert = require("support.assert")
local Setting = require("source.local.setting")

Assert.is_true(Setting.isKindleDocuments("/mnt/us/documents"))
Assert.is_true(Setting.isKindleDocuments("/mnt/us/documents/"))
Assert.is_false(Setting.isKindleDocuments("/mnt/us/documents/Books"))
Assert.is_false(Setting.isKindleDocuments("/mnt/us"))
Assert.is_false(Setting.isKindleDocuments(nil))
