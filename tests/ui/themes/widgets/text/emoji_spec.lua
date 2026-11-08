--[[--
emoji 行内图片映射：组合序列不拆字，普通符号不被误识别。
@module tests.ui.themes.widgets.text.emoji_spec
--]]
local Assert = require("support.assert")
local Emoji = require("ui.themes.widgets.text.emoji")

local custom = { ["[笑]"] = { url = "fixture.png" } }
local images = Emoji.images("甲😀😀👍🏽👩‍💻❤️🇨🇳1️⃣[笑]乙", custom)
Assert.matches(images["😀"].url, "/1f600%.png$")
Assert.matches(images["👍🏽"].url, "/1f44d%-1f3fd%.png$")
Assert.matches(images["👩‍💻"].url, "/1f469%-200d%-1f4bb%.png$")
Assert.matches(images["❤️"].url, "/2764%.png$", "非 ZWJ 序列不带 VS16")
Assert.matches(images["🇨🇳"].url, "/1f1e8%-1f1f3%.png$")
Assert.matches(images["1️⃣"].url, "/31%-20e3%.png$")
Assert.eq(images["[笑]"], custom["[笑]"], "源提供的图片优先且不拷贝对象")
Assert.is_nil(custom["😀"], "不修改源与缓存持有的原表")
Assert.is_nil(images["🏽"], "肤色修饰符不单独画")
Assert.is_nil(next(Emoji.images("中文 123 # ★ ♥ → [因果]")))
Assert.is_nil(next(Emoji.images("")))
Assert.is_nil(next(Emoji.images("🇨")), "不完整国旗不猜图片")
Assert.is_nil(Emoji.images("😀‍中文")["😀‍中"], "ZWJ 后的普通文字不能吞进图片")

return true
