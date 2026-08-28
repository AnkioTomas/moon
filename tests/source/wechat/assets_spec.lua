--[[--
source.wechat.assets 离线用例

@module tests.source.wechat.assets_spec
--]]

local Assert = require("support.assert")

package.preload["source.wechat.assets"] = nil
package.loaded["source.wechat.assets"] = nil
package.preload["source.wechat.auth"] = nil
package.loaded["source.wechat.auth"] = nil

local Assets = require("source.wechat.assets")

do
    local html = '<img src="foo.jpg"/><img src="https://cdn/x.png?w=1"/>'
    local out = Assets.rewriteImageSources(html, {
        ["foo.jpg"] = "images/aaa.png",
        ["https://cdn/x.png"] = "images/bbb.png",
    })
    Assert.matches(out, 'src="images/aaa.png"')
    Assert.matches(out, 'src="images/bbb.png"')
end

local function tarHeader(name, size)
    local h = string.rep("\0", 512)
    local function poke(off, s)
        h = h:sub(1, off - 1) .. s .. h:sub(off + #s)
    end
    poke(1, name:sub(1, 100))
    poke(125, string.format("%011o", size))
    poke(157, "0")
    poke(258, "ustar\x00")
    poke(264, "00")
    local sum = 0
    for i = 1, 512 do
        sum = sum + h:byte(i)
    end
    poke(149, string.format("%06o\0 ", sum))
    return h
end

local function makeTar(name, data)
    local padded = data .. string.rep("\0", (512 - (#data % 512)) % 512)
    return tarHeader(name, #data) .. padded .. string.rep("\0", 1024)
end

do
    local png = "\137PNG\r\n\026\n" .. string.rep("x", 32)
    local tar = makeTar("pic.png", png)
    package.preload["source.wechat.auth"] = function()
        return {
            webGetAsync = function(url, _opts, cb)
                if url:find("/tar/", 1, true) then
                    cb(tar)
                else
                    cb(nil, "unexpected url")
                end
            end,
        }
    end
    package.loaded["source.wechat.auth"] = nil
    package.loaded["source.wechat.assets"] = nil
    Assets = require("source.wechat.assets")

    local done, html_out = false, nil
    Assets.localizeAsync("book-1", {
        uid = "u1",
        tar = "/web/book/chapter/tar/abc",
    }, '<img src="pic.png"/>', "https://weread.qq.com/web/reader/1/u1", function(html)
        done = true
        html_out = html
    end)
    Assert.is_true(done)
    Assert.matches(html_out, 'src="images/[0-9a-f]+%.png"')
end

do
    local png = "\137PNG\r\n\026\n" .. string.rep("y", 16)
    local remote = "https://res.weread.qq.com/wrepub/CB_test.png"
    package.preload["source.wechat.auth"] = function()
        return {
            webGetAsync = function(url, opts, cb)
                Assert.eq(url, remote)
                Assert.is_true(opts.skip_auth_retry)
                Assert.is_true(opts.allow_redirects)
                Assert.eq(opts.headers["Referer"], "https://weread.qq.com/")
                cb(png)
            end,
        }
    end
    package.loaded["source.wechat.auth"] = nil
    package.loaded["source.wechat.assets"] = nil
    Assets = require("source.wechat.assets")

    local sample = string.format(
        '<div class="bodyPic1"><img src="%s" data-w="720px"/></div>',
        remote
    )
    local done, html_out = false, nil
    Assets.localizeAsync("book-2", { uid = "u2" }, sample, "https://weread.qq.com/web/reader/2/u2", function(html)
        done = true
        html_out = html
    end)
    Assert.is_true(done)
    Assert.matches(html_out, 'src="images/[0-9a-f]+%.png"')
    Assert.is_false(require("utils.text").hasRemoteImageSrc(html_out))
end
