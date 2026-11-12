--[[--
source.wechat.assets 离线用例

@module tests.source.wechat.assets_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["source.wechat.assets"] = nil
package.loaded["source.wechat.assets"] = nil
package.preload["source.wechat.auth"] = nil
package.loaded["source.wechat.auth"] = nil

local Assets = require("source.wechat.assets")

local function noStyle()
    error("不该拉样式表")
end

do
    local html = '<img src="foo.jpg"/><img src="https://cdn/x.png?w=1"/>'
    local out = require("source.assets").rewriteImageSources(html, {
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
    }, '<img src="pic.png"/>', "https://weread.qq.com/web/reader/1/u1", noStyle, function(html)
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
    Assets.localizeAsync("book-2", { uid = "u2" }, sample, "https://weread.qq.com/web/reader/2/u2", noStyle,
        function(html)
            done = true
            html_out = html
        end)
    Assert.is_true(done)
    Assert.matches(html_out, 'src="images/[0-9a-f]+%.png"')
    Assert.is_false(require("utils.text").hasRemoteImageSrc(html_out))
end

-- 脚注图标 + 整书样式表：只改 src / href，其余字节原样；样式表每本书只拉一次。
-- 拉不到时去掉坏相对 link，注入 .content 兜底缩进（否则段首顶格）。
do
    local Paths = require("utils.paths")
    local work_dir = Paths.bookWorkDir("book-3", "wechat")
    os.remove(work_dir .. "/stylesheets.css")
    local head = '<?xml version="1.0"?><html><head><title></title>'
    local link = '<link href="../Styles/stylesheets.css" rel="stylesheet" type="text/css" />'
    local abs = '<link href="https://cdn/x.css" rel="stylesheet" />'
    local fix = "<style>h1 + h1, .moon-title h1 { page-break-before: avoid; }"
        .. " body.bgimg-1 { background-image: none; }"
        .. " .moon-title { background-image: url(images/bq.jpg); background-size: cover;"
        .. " background-position: center bottom; height: 90vh; padding-top: 30vh;"
        .. " page-break-before: always; page-break-after: always; }</style>"
    local fallback = "<style type=\"text/css\">"
        .. ".content,.content1{text-indent:2em;text-align:justify}"
        .. ".bold,.firstTitle,.secondTitle,.thirdTitle,.contentCR,.contentCR1,.contentCR2{text-indent:0}"
        .. "</style>"
    local body = '</head><body><p class="content">正文<img class="qqreader-footnote" alt="注文" '
        .. 'src="../Images/note.png" /></p></body></html>'
    local sample = head .. link .. abs .. body

    local fetches = 0
    local function fetchStyle(css)
        return function(done)
            fetches = fetches + 1
            done(css)
            return { cancel = function() end }
        end
    end
    local function run(fetch)
        local out
        Assets.localizeAsync("book-3", { uid = "u3" }, sample, nil, fetch, function(html) out = html end)
        return out
    end

    local failed = run(fetchStyle(nil))
    Assert.eq(fetches, 1)
    Assert.is_nil(failed:find(link, 1, true), "拉不到样式表去掉坏相对 link")
    Assert.is_true(failed:find(abs, 1, true) ~= nil, "绝对 css link 保留")
    Assert.is_true(failed:find("text-indent:2em", 1, true) ~= nil, "注入兜底缩进")
    Assert.is_true(failed:find(fallback, 1, true) ~= nil, "兜底样式整段写入")
    Assert.is_nil(io.open(work_dir .. "/stylesheets.css", "rb"))

    local out = run(fetchStyle(".content{text-indent:2em}"))
    Assert.eq(fetches, 2)
    local icon = out:match('src="(images/[0-9a-f]+%.png)"')
    Assert.is_true(icon ~= nil, "脚注图标落地")
    local f = assert(io.open(work_dir .. "/" .. icon, "rb"))
    Assert.eq(f:read(4), "\137PNG")
    f:close()
    Assert.eq(out, head .. '<link href="stylesheets.css" rel="stylesheet" type="text/css" />' .. abs .. fix
        .. body:gsub("%.%./Images/note%.png", icon))
    f = assert(io.open(work_dir .. "/stylesheets.css", "rb"))
    Assert.eq(f:read("*a"), ".content{text-indent:2em}")
    f:close()

    Assert.eq(run(fetchStyle("不该再拉")), out, "已缓存直接改链接")
    Assert.eq(fetches, 2)
end

-- 章首页：body.bgimg-1 的开头出血图丢掉，连续 h1 包进整页容器；样式表里 ../Images/ 改指工作目录 images/
do
    local Paths = require("utils.paths")
    local work_dir = Paths.bookWorkDir("book-4", "wechat")
    Paths.ensureDir(work_dir)
    os.remove(work_dir .. "/stylesheets.css")
    local src = '<html><head><link href="../Styles/stylesheets.css" rel="stylesheet" /></head>'
        .. '<body class="bgimg-1">\n<p class="bleed-pic"><img src="a.png" /></p>\n'
        .. '<h1 class="firstTitle">第</h1>\n<h1 class="firstTitle">一</h1>\n<p class="content">正文</p></body></html>'
    local out
    Assets.localizeAsync("book-4", { uid = "u4" }, src, nil, function(done)
        done("a{background:url(../Images/bq.jpg)}")
        return { cancel = function() end }
    end, function(html) out = html end)
    Assert.is_true(out:find('<body class="bgimg-1">\n<div class="moon-title"><h1 class="firstTitle">第</h1>\n'
        .. '<h1 class="firstTitle">一</h1>\n</div><p class="content">正文</p>', 1, true) ~= nil, out)
    Assert.is_nil(out:find("bleed-pic", 1, true))
    local f = assert(io.open(work_dir .. "/stylesheets.css", "rb"))
    Assert.eq(f:read("*a"), "a{background:url(images/bq.jpg)}")
    f:close()
end

-- 脚注图标路径不统一：qqreader-footnote 或任意 note.png 都注入自带「注」标，不要求写成 ../Images/note.png
do
    local Paths = require("utils.paths")
    local cases = {
        { book = "book-fn-bare", src = "note.png" },
        { book = "book-fn-images", src = "Images/note.png" },
        { book = "book-fn-parent", src = "../Images/note.png" },
        { book = "book-fn-noclass", src = "note.png", plain = true },
    }
    local icons = {}
    for _, case in ipairs(cases) do
        local html
        if case.plain then
            html = string.format('<p><img alt="注文" src="%s" /></p>', case.src)
        else
            html = string.format(
                '<p><img class="qqreader-footnote" alt="注文" src="%s" /></p>',
                case.src
            )
        end
        local out
        Assets.localizeAsync(case.book, { uid = "u" }, html, nil, noStyle, function(result)
            out = result
        end)
        local icon = out:match('src="(images/[0-9a-f]+%.png)"')
        Assert.is_true(icon ~= nil, "脚注图标落地: " .. case.src)
        Assert.is_nil(out:find(case.src, 1, true), "原路径被改写: " .. case.src)
        local work_dir = Paths.bookWorkDir(case.book, "wechat")
        local f = assert(io.open(work_dir .. "/" .. icon, "rb"))
        Assert.eq(f:read(4), "\137PNG")
        f:close()
        icons[#icons + 1] = icon
    end
    for i = 2, #icons do
        Assert.eq(icons[i], icons[1], "同一自带图标，内容寻址复用")
    end
end
