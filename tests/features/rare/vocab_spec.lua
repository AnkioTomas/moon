--[[-- features.rare.vocab：生字本词表 → 集合（原词、小写、每个汉字）；没有生字本返回空。 --]]
local Assert = require("support.assert")
local Vocab = require("features.rare.vocab")

local set = Vocab.toSet({ "觊觎", "Obdurate", "", "龘" })
Assert.is_true(set["觊觎"])
Assert.is_true(set["觊"] and set["觎"] and set["龘"], "每个汉字")
Assert.is_true(set["Obdurate"] and set["obdurate"], "英文另存小写")
Assert.is_nil(set["O"], "ASCII 字母不单独算")

package.loaded["datastorage"] = { getSettingsDir = function() return "/nonexistent-moon-test" end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
Assert.eq(next(Vocab.set()), nil, "没有生字本")
