--[[-- update.init：版本比较与 GitHub Release 资产约束。 --]]

local Assert = require("support.assert")

package.preload["ui/widget/confirmbox"] = function() return { new = function(_, opts) return opts end } end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, opts) return opts end } end
package.preload["json"] = function() return { decode = function(value) return value end } end
package.preload["http.request"] = function() return {} end
package.preload["utils.paths"] = function() return {} end
package.preload["utils.settings"] = function() return {} end
package.preload["workers.job"] = function() return {} end
package.preload["update.install"] = function() return { MAX_ARCHIVE_BYTES = 100 } end
package.preload["bookversion"] = function() return "1.2.3" end

local Update = require("update.init")

Assert.is_true(Update._newer("1.2.4", "1.2.3"))
Assert.is_true(Update._newer("2.0.0", "1.9.9"))
Assert.is_false(Update._newer("1.2.3", "1.2.3"))
Assert.is_false(Update._newer("1.2.2", "1.2.3"))

local hash = string.rep("a", 64)
local release = {
    tag_name = "v1.2.4",
    assets = {
        {
            name = "book.koplugin-v1.2.4.zip",
            browser_download_url = "https://github.com/AnkioTomas/moon/releases/download/v1.2.4/book.koplugin-v1.2.4.zip",
            digest = "sha256:" .. hash,
        },
    },
}
local parsed, err = Update._parseRelease(release)
Assert.not_nil(parsed, err)
Assert.eq(parsed.version, "1.2.4")
Assert.eq(parsed.sha256, hash)
Assert.is_true(parsed.available)

release.assets[1].digest = nil
local missing, missing_err = Update._parseRelease(release)
Assert.is_nil(missing)
Assert.matches(missing_err, "checksum")

release.assets[2] = {
    name = "book.koplugin-v1.2.4.zip.sha256",
    browser_download_url = "https://github.com/AnkioTomas/moon/releases/download/v1.2.4/book.koplugin-v1.2.4.zip.sha256",
}
parsed, err = Update._parseRelease(release)
Assert.not_nil(parsed, err)
Assert.eq(parsed.checksum_url, release.assets[2].browser_download_url)

-- 同名资产若跳到任意主机，不能拿来更新。
release.assets[1].browser_download_url = "https://example.com/book.koplugin-v1.2.4.zip"
local foreign, foreign_err = Update._parseRelease(release)
Assert.is_nil(foreign)
Assert.matches(foreign_err, "plugin archive")

return true
