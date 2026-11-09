--[[-- features.ime.field：system 模式下哪些字段必须留给内置键盘 / 不弹键盘。 --]]
local Assert = require("support.assert")

local Field = require("features.ime.field")

Assert.is_true(Field.usesBuiltin({ input_type = "number" }), "数字字段走内置数字层")
Assert.is_true(Field.usesBuiltin({ text_type = "password" }), "密码字段走内置键盘")
Assert.is_true(Field.usesBuiltin({ is_password_type = true }), "密码标记走内置键盘")
Assert.is_false(Field.usesBuiltin({}), "普通字段交给系统后端")
Assert.is_false(Field.usesBuiltin({ readonly = true }), "只读不是内置键盘场景")
Assert.is_false(Field.usesBuiltin(nil))

Assert.is_true(Field.isReadonly({ readonly = true }))
Assert.is_false(Field.isReadonly({}))
Assert.is_false(Field.isReadonly(nil))
