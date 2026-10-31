--[[--
source.category_setting 离线用例

@module tests.source.category_setting_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Settings = require("utils.settings")
local CategorySetting = require("source.category_setting")

local SOURCE = "wechat"
local cfg = Settings.getSource(SOURCE)

cfg.category_as_group = nil
Settings.saveSource(SOURCE, cfg)
Assert.is_true(CategorySetting.enabled(SOURCE), "缺省开")
Assert.eq(CategorySetting.apply(SOURCE, "玄幻", "追更"), "追更", "缺省：只用分组")
Assert.is_nil(CategorySetting.apply(SOURCE, "玄幻", nil), "缺省：没进组不写题材")

cfg.category_as_group = false
Settings.saveSource(SOURCE, cfg)
Assert.is_false(CategorySetting.enabled(SOURCE))
Assert.eq(CategorySetting.apply(SOURCE, "玄幻", "追更"), "玄幻", "关：题材优先，忽略分组")
Assert.eq(CategorySetting.apply(SOURCE, "玄幻", nil), "玄幻")
Assert.is_nil(CategorySetting.apply(SOURCE, nil, "追更"))
Assert.is_nil(CategorySetting.apply(SOURCE, "", "追更"))

cfg.category_as_group = true
Settings.saveSource(SOURCE, cfg)
Assert.is_true(CategorySetting.enabled(SOURCE))
Assert.eq(CategorySetting.apply(SOURCE, "玄幻", "追更"), "追更", "开：只用分组")
Assert.is_nil(CategorySetting.apply(SOURCE, "玄幻", nil), "开：没进组不写题材")
Assert.is_nil(CategorySetting.apply(SOURCE, "玄幻", ""), "开：空分组等同没进组")

cfg.category_as_group = false
Settings.saveSource(SOURCE, cfg)
