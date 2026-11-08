--[[--
本地书库目录确认前的提醒：Kindle documents，以及英文数字以外的字符。

@module tests.source.local.documents_warn_spec
--]]

local Assert = require("support.assert")
local Setting = require("source.local.setting")

Assert.is_true(Setting.isKindleDocuments("/mnt/us/documents"))
Assert.is_true(Setting.isKindleDocuments("/mnt/us/documents/"))
Assert.is_false(Setting.isKindleDocuments("/mnt/us/documents/Books"))
Assert.is_false(Setting.isKindleDocuments("/mnt/us"))
Assert.is_false(Setting.isKindleDocuments(nil))

Assert.is_false(Setting.hasNonAlnum("/mnt/us/documents/Books"))
Assert.is_false(Setting.hasNonAlnum("/storage/emulated/0"))
Assert.is_false(Setting.hasNonAlnum("Books"))
Assert.is_false(Setting.hasNonAlnum("123"))
Assert.is_false(Setting.hasNonAlnum("/mnt/us/my-books"))
Assert.is_false(Setting.hasNonAlnum("/mnt/us/my_books"))
Assert.is_false(Setting.hasNonAlnum("/"))
Assert.is_false(Setting.hasNonAlnum(""))
Assert.is_false(Setting.hasNonAlnum(nil))
Assert.is_true(Setting.hasNonAlnum("/mnt/us/书籍"))
Assert.is_true(Setting.hasNonAlnum("/mnt/us/my books"))
Assert.is_true(Setting.hasNonAlnum("/mnt/us/my.books"))
Assert.is_true(Setting.hasNonAlnum("小说"))
