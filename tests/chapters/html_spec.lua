--[[--
chapters.html 离线用例

@module tests.chapters.html_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.loaded["chapters.html"] = nil
local Html = require("chapters.html")

-- xmlEscape / looksLikeHtml / textToBody 已迁 utils.text，由 tests/utils/text_spec.lua 覆盖

do
    local body, title = Html.normalizeBody({ title = "T1", text = "line" })
    Assert.eq(title, "T1")
    Assert.is_true(body:find("<p>line</p>", 1, true) ~= nil)
end

do
    local dest = os.tmpname() .. ".html"
    local ok, err = Html.write(dest, { title = "章", html = "<p>正文</p>" })
    Assert.eq(ok, true, err)
    Assert.eq(err, nil)
    local f = io.open(dest, "rb")
    Assert.is_true(f ~= nil)
    local content = f:read("*a")
    f:close()
    Assert.is_true(content:find("<!DOCTYPE html>", 1, true) ~= nil)
    Assert.is_true(content:find("<p>正文</p>", 1, true) ~= nil)
    Assert.is_true(Html.isValid(dest))
    os.remove(dest)
end

do
    local ok, err = Html.write("/tmp/moon-empty-chapter.html", { title = "x" })
    Assert.is_nil(ok)
    Assert.is_true(type(err) == "string")
end
