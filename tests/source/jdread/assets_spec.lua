--[[--
source.jdread.assets 离线用例

@module tests.source.jdread.assets_spec
--]]

local Assert = require("support.assert")

local png = "\137PNG\r\n\026\n" .. string.rep("x", 32)
local remote = "https://img30.360buyimg.com/ebookadmin/jfs/x.jpg"

local last_req
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            last_req = { url = url, opts = opts }
            if url == remote then
                cb(png)
            else
                cb(nil, "unexpected url")
            end
            return { cancel = function() end }
        end,
    }
end

package.loaded["http.request"] = nil
package.loaded["source.jdread.assets"] = nil

local Assets = require("source.jdread.assets")
local Text = require("utils.text")

do
    local html = '<img src="https://img30.360buyimg.com/ebookadmin/jfs/x.jpg" href="./image/Images/x.jpg"/>'
    local out = Assets.rewriteImageSources(html, {
        [remote] = "images/aaa.jpg",
    })
    Assert.matches(out, 'src="images/aaa.jpg"')
    Assert.matches(out, 'href="images/aaa.jpg"')
    Assert.is_nil(out:find("./image/Images/x.jpg", 1, true))
end

do
    local sample = string.format(
        '<p class="img_content"><img alt="" src="%s" href="./image/Images/image_45_0_m.jpg"/></p>',
        remote
    )
    local done, html_out = false, nil
    Assets.localizeAsync("30885033", sample, function(html)
        done = true
        html_out = html
    end)
    Assert.is_true(done)
    Assert.eq(last_req.url, remote)
    Assert.eq(last_req.opts.allow_redirects, true)
    Assert.eq(last_req.opts.headers["Referer"], "https://e.m.jd.com/")
    Assert.matches(html_out, 'src="images/[0-9a-f]+%.png"')
    Assert.matches(html_out, 'href="images/[0-9a-f]+%.png"')
    Assert.is_nil(html_out:find("./image/Images/", 1, true))
    Assert.is_false(Text.hasRemoteImageSrc(html_out))
end

do
    local html = '<p>无图正文</p>'
    local done, html_out = false, nil
    Assets.localizeAsync("30885033", html, function(out)
        done = true
        html_out = out
    end)
    Assert.is_true(done)
    Assert.eq(html_out, html)
end

do
    package.preload["http.request"] = function()
        return {
            get = function(_url, _opts, cb)
                cb(nil, "cdn down")
                return { cancel = function() end }
            end,
        }
    end
    package.loaded["http.request"] = nil
    package.loaded["source.jdread.assets"] = nil
    Assets = require("source.jdread.assets")

    local sample = '<img src="' .. remote .. '"/>'
    local html_out
    Assets.localizeAsync("30885033", sample, function(html)
        html_out = html
    end)
    Assert.eq(html_out, sample)
end
