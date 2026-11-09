--[[--
dex 安装：加载前校验 sha256、复制到私有缓存、临时文件 + rename 原子替换、
chmod 444。用真实文件与真实 sha256（已知向量），不碰 Android。

@module tests.features.system_ime.dex_spec
--]]

local Assert = require("support.assert")
local Dex = require("features.system_ime.dex")

-- "abc" 的 SHA-256，独立已知向量（不经过被测代码计算）
local ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local BAD_SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"

local function writeFile(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function removeFile(path)
    if path then os.remove(path) end
end

-- ── 校验 ─────────────────────────────────────────────
local missing = os.tmpname()
removeFile(missing)
local ok, err = Dex.verify(missing, ABC_SHA256)
Assert.is_nil(ok)
Assert.matches(err, "missing")

local good = os.tmpname()
writeFile(good, "abc")
Assert.is_true(Dex.verify(good, ABC_SHA256), "哈希一致")
local bad_ok, bad_err = Dex.verify(good, BAD_SHA256)
Assert.is_nil(bad_ok)
Assert.matches(bad_err, "sha256")

-- ── 安装：复制 + 只读 ────────────────────────────────
local dest = os.tmpname() .. ".dex"
removeFile(dest)
local installed, install_err = Dex.stage(good, dest, ABC_SHA256)
Assert.eq(installed, dest, "返回目标路径: " .. tostring(install_err))
Assert.eq(readFile(dest), "abc", "内容复制完整")
local perms = io.popen("stat -c %a '" .. dest .. "' 2>/dev/null"):read("*l")
Assert.eq(perms, "444", "目标文件只读，满足 Android 14+ 动态代码加载")

-- 目标已存在（旧版只读文件）：临时文件 + rename 覆盖，不直接写目标
local replaced = os.tmpname() .. ".dex"
writeFile(replaced, "stale")
os.execute("chmod 444 '" .. replaced .. "' 2>/dev/null")
local stage_ok = Dex.stage(good, replaced, ABC_SHA256)
Assert.is_true(stage_ok, "只读旧文件也能原子替换")
Assert.eq(readFile(replaced), "abc")

-- 哈希不符：不写目标，避免把坏 dex 装进缓存
local mismatch_dest = os.tmpname() .. ".dex"
removeFile(mismatch_dest)
local staged, stage_err = Dex.stage(good, mismatch_dest, BAD_SHA256)
Assert.is_nil(staged)
Assert.matches(stage_err, "sha256")
Assert.is_nil(readFile(mismatch_dest), "校验失败不落盘")

removeFile(good)
removeFile(dest)
removeFile(replaced)
removeFile(mismatch_dest)
