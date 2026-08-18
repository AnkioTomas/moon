--[[--
utils.paths 离线用例

目录布局拼接、sanitizeSourceId 契约、slugFor(md5) 稳定性，
以及 ensureLayout/ensureBookWork 的真实建目录行为（唯一源 id test_paths_spec，用后即清）。

@module tests.paths_spec
--]]

local Assert = require("support.assert")

-- 其它 spec（如 chapters/ensure、chapters/nav）会把 libs/libkoreader-lfs 的假桩
-- 泄进 package.preload/package.loaded 且不清理，runner 还会在文件间原样传递；
-- 本文件必须用真实 native lfs / sha2 验证建目录与 md5，先强制清掉再 require。
for _, name in ipairs({ "libs/libkoreader-lfs", "ffi/sha2", "utils.paths" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")

local TEST_SOURCE = "test_paths_spec"

--- 仅清理本测试创建的 test_paths_spec 子树（目录为空才删得掉，不碰 config/ 其它数据）
--- 用 lfs.rmdir 而非 os.remove：nav_spec 等会把 os.remove 换成内存假桩且不还原
local function cleanup()
    lfs.rmdir(Paths.bookWorkDir("stable/id", TEST_SOURCE))
    lfs.rmdir(Paths.imageDir(TEST_SOURCE))
    lfs.rmdir(Paths.bookDir(TEST_SOURCE))
    lfs.rmdir(Paths.sourceCacheDir(TEST_SOURCE))
end

-- 上次失败可能遗留，先清一遍保证幂等
cleanup()

-- sanitizeSourceId：正常字符保留
do
    Assert.eq(Paths.sanitizeSourceId("moon"), "moon")
    Assert.eq(Paths.sanitizeSourceId("webdav_2.0-x"), "webdav_2.0-x")
end

-- sanitizeSourceId：非法字符（空格/斜杠/冒号等）替换为 _
do
    Assert.eq(Paths.sanitizeSourceId("a b"), "a_b")
    Assert.eq(Paths.sanitizeSourceId("a/b"), "a_b")
    Assert.eq(Paths.sanitizeSourceId("a:b"), "a_b")
    -- 中文按字节替换：「中文」6 字节 → 6 个下划线
    Assert.eq(Paths.sanitizeSourceId("中文"), "______")
end

-- sanitizeSourceId：缺参/空串直接 error（禁止猜活跃源）
do
    Assert.errors(function() Paths.sanitizeSourceId(nil) end, "source_id required")
    Assert.errors(function() Paths.sanitizeSourceId("") end, "source_id required")
    Assert.errors(function() Paths.sanitizeSourceId(123) end, "source_id required")
end

-- slugFor：md5 稳定性
do
    local s = "/webdav/书库/a book.epub"
    Assert.eq(Paths.slugFor(s), Paths.slugFor(s))
    Assert.is_true(Paths.slugFor("/a") ~= Paths.slugFor("/b"))
    -- 32 位小写 hex，含 / 的 webdav 路径不会出现在结果里
    Assert.len(Paths.slugFor(s), 32)
    Assert.matches(Paths.slugFor(s), "^[0-9a-f]+$")
    Assert.is_nil(Paths.slugFor(s):find("/", 1, true))
    -- 缺参直接失败：nil/空串会撞到一个固定 slug，多本书共用工作目录
    Assert.errors(function() Paths.slugFor(nil) end, "stable_id required")
    Assert.errors(function() Paths.slugFor("") end, "stable_id required")
    Assert.errors(function() Paths.slugFor(123) end, "stable_id required")
end

-- 路径拼接正确性
do
    local root = Paths.root()
    Assert.matches(root, "/config/%.moon$")
    Assert.eq(Paths.cacheDir(), root .. "/cache")
    Assert.eq(Paths.sourceCacheDir("moon"), root .. "/cache/moon")
    Assert.eq(Paths.bookDir("moon"), root .. "/cache/moon/book")
    Assert.eq(Paths.imageDir("moon"), root .. "/cache/moon/image")
    -- 源 id 非法字符在拼接前先 sanitize
    Assert.eq(Paths.sourceCacheDir("a/b"), root .. "/cache/a_b")
    Assert.eq(Paths.coverPath("sid", "moon"),
        root .. "/cache/moon/image/" .. Paths.slugFor("sid") .. ".png")
    Assert.eq(Paths.bookWorkDir("sid", "moon"),
        root .. "/cache/moon/book/" .. Paths.slugFor("sid"))
    Assert.eq(Paths.dbPath(), root .. "/book.sqlite3")
    Assert.eq(Paths.settingsDir(), root .. "/settings")
    Assert.eq(Paths.fontsDir(), root .. "/fonts")
    Assert.eq(Paths.commonPath(), root .. "/settings/common.lua")
    Assert.eq(Paths.sourcePath("wechat"), root .. "/settings/wechat.lua")
    -- sourcePath(nil) 默认 moon
    Assert.eq(Paths.sourcePath(nil), root .. "/settings/moon.lua")
end

-- ensureLayout：真实创建 .moon/cache/<source>/{book,image}，重复调用幂等
do
    Paths.ensureLayout(TEST_SOURCE)
    Assert.eq(lfs.attributes(Paths.sourceCacheDir(TEST_SOURCE), "mode"), "directory")
    Assert.eq(lfs.attributes(Paths.bookDir(TEST_SOURCE), "mode"), "directory")
    Assert.eq(lfs.attributes(Paths.imageDir(TEST_SOURCE), "mode"), "directory")
    Paths.ensureLayout(TEST_SOURCE)
    Assert.eq(lfs.attributes(Paths.sourceCacheDir(TEST_SOURCE), "mode"), "directory")
end

-- ensureBookWork：在 ensureLayout 基础上再建 book/<slug>/
do
    Paths.ensureBookWork("stable/id", TEST_SOURCE)
    Assert.eq(lfs.attributes(Paths.bookWorkDir("stable/id", TEST_SOURCE), "mode"), "directory")
    Assert.eq(lfs.attributes(Paths.bookDir(TEST_SOURCE), "mode"), "directory")
    local dir = Paths.bookWorkDir("stable/id", TEST_SOURCE)
    Assert.eq(lfs.attributes(dir, "mode"), "directory")
    -- 幂等：重复调用不重写不报错
    Paths.ensureBookWork("stable/id", TEST_SOURCE)
end

-- splitBookWorkPath：只认 cache/<source>/book/<slug>/<file> 布局
do
    local dir = Paths.bookWorkDir("stable/id", TEST_SOURCE)
    local d, f = Paths.splitBookWorkPath(dir .. "/3.html")
    Assert.eq(d, dir)
    Assert.eq(f, "3.html")
    local _, _, source_id, slug = Paths.splitBookWorkPath(dir .. "/3.html")
    Assert.eq(source_id, TEST_SOURCE)
    Assert.eq(slug, Paths.slugFor("stable/id"))
    local d2, f2 = Paths.splitBookWorkPath(dir .. "/book.epub")
    Assert.eq(d2, dir)
    Assert.eq(f2, "book.epub")
    Assert.is_nil(Paths.splitBookWorkPath("/other/plain.epub"))
    Assert.is_nil(Paths.splitBookWorkPath(Paths.imageDir(TEST_SOURCE) .. "/x.png"), "image 段不算书籍工作目录")
    Assert.is_nil(Paths.splitBookWorkPath(dir .. "/sub/3.html"), "更深层级不算")
    Assert.is_true(Paths.isMoonPath(Paths.root() .. "/cache/unknown/file"))
    Assert.is_false(Paths.isMoonPath(Paths.root() .. "-other/file"))
end

-- 只删本测试创建的目录（空目录才能删，天然保护误删）
cleanup()
Assert.is_nil(lfs.attributes(Paths.sourceCacheDir(TEST_SOURCE)))
