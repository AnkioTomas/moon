--[[--
source.assets 离线用例：远程 img 落地由调用方注入 download。

@module tests.source.assets_spec
--]]

local Assert = require("support.assert")
local Assets = require("source.assets")
local Text = require("utils.text")
local Config = require("support.config")

local png = "\137PNG\r\n\026\n" .. string.rep("x", 32)
local remote = "https://img30.360buyimg.com/ebookadmin/jfs/x.jpg"
local images_dir = Config.dir() .. "/.moon/cache/jdread/book/assets-spec/images"

do
    local html = '<img src="foo.jpg"/><img src="https://cdn/x.png?w=1"/>'
    local out = Assets.rewriteImageSources(html, {
        ["foo.jpg"] = "images/aaa.png",
        ["https://cdn/x.png"] = "images/bbb.png",
    })
    Assert.matches(out, 'src="images/aaa.png"')
    Assert.matches(out, 'src="images/bbb.png"')
end

do
    local html = '<img src="https://img30.360buyimg.com/ebookadmin/jfs/x.jpg" href="./image/Images/x.jpg"/>'
    local out = Assets.rewriteImageSources(html, {
        [remote] = "images/aaa.jpg",
    })
    Assert.matches(out, 'src="images/aaa.jpg"')
    Assert.matches(out, 'href="images/aaa.jpg"')
    Assert.is_nil(out:find("./image/Images/x.jpg", 1, true))
end

local function downloadOk(url, cb)
    Assert.eq(url, remote)
    cb(png)
    return { cancel = function() end }
end

do
    local sample = string.format(
        '<p class="img_content"><img alt="" src="%s" href="./image/Images/image_45_0_m.jpg"/></p>',
        remote
    )
    local done, html_out = false, nil
    Assets.localizeAsync(sample, images_dir, downloadOk, function(html)
        done = true
        html_out = html
    end)
    Assert.is_true(done)
    Assert.matches(html_out, 'src="images/[0-9a-f]+%.png"')
    Assert.matches(html_out, 'href="images/[0-9a-f]+%.png"')
    Assert.is_nil(html_out:find("./image/Images/", 1, true))
    Assert.is_false(Text.hasRemoteImageSrc(html_out))
end

do
    local html = '<p>无图正文</p>'
    local called = false
    local html_out
    Assets.localizeAsync(html, images_dir, function()
        called = true
    end, function(out)
        html_out = out
    end)
    Assert.is_false(called)
    Assert.eq(html_out, html)
end

do
    local sample = '<img src="' .. remote .. '"/>'
    local html_out
    Assets.localizeAsync(sample, images_dir, function(_url, cb)
        cb(nil, "cdn down")
        return { cancel = function() end }
    end, function(html)
        html_out = html
    end)
    Assert.eq(html_out, sample)
end

-- 写盘失败：不返回 href、不留目标文件，下次同图仍会重写而不是复用半截文件。
do
    local md5 = require("ffi/sha2").md5
    local data = "\137PNG\r\n\026\n" .. string.rep("w", 40)
    local target = images_dir .. "/" .. md5(data) .. ".png"
    os.remove(target)
    local real_open = io.open
    io.open = function(path, mode)
        if mode == "wb" then
            return { write = function() return nil, "disk full" end, close = function() return true end }
        end
        return real_open(path, mode)
    end
    local href = Assets.materializeImage(images_dir, data)
    io.open = real_open
    Assert.is_nil(href)
    Assert.is_nil(io.open(target, "rb"))
    Assert.is_nil(io.open(target .. ".part", "rb"))

    Assert.eq(Assets.materializeImage(images_dir, data), "images/" .. md5(data) .. ".png")
    local f = assert(io.open(target, "rb"))
    Assert.eq(f:read("*a"), data)
    f:close()
end
