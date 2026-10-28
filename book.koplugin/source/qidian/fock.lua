--[[--
起点 VIP 章节正文解密（Fock）：阅文 wasm 的起点构建参数 + 子进程编排，宿主在 `source.yuewen_fock`。
网页端用它解密 `chapterInfo.content`。

@module source.qidian.fock
--]]--

local Shared = require("source.yuewen_fock")
local FontRestore = require("source.yuewen_fonts")
local JSON = require("json")

local Fock = {}

-- 起点 font 层的字形与参考 Noto 偶有 0.65~0.75 的形近字（如 䵻→对），比 QQ阅读放宽一点。
local FONT_THRESHOLD = 0.65
local RESTORE_OPTS = { dedupe = true, confusions = true, threshold = FONT_THRESHOLD }

---@param info table chapterInfo
---@return table
local function fontData(info)
    local raw = info.randomFont
    assert(type(raw) == "string" and raw ~= "", "qidian randomFont missing")
    local ok, random = pcall(JSON.decode, raw)
    if not ok or type(random) ~= "table" then
        error("qidian randomFont decode failed: " .. tostring(random))
    end
    return { css = info.css or "", randomFont = random }
end

--- 还原字体层；抛错转成 `{ err }`，不让子进程崩在 on_failed 里丢上下文。
---@return { text: string|nil, err: string|nil }
local function restore(html, info, fixed_font)
    local ok, text = pcall(FontRestore.restore, html, fontData(info), fixed_font, RESTORE_OPTS)
    if not ok then return { err = "font: " .. tostring(text) } end
    return { text = text }
end

local HOST = {
    ["location.hostname"] = "vipreader.qidian.com",
    ["location.protocol"] = "https:",
}

---@type YuewenFockBuild
local BUILD = {
    wasm = "source.qidian.fock_wasm",
    callback = 22685,
    stack = 5274992,
    exports = { ctors = "g", main = "m", set_uid = "h", set_key = "i", decrypt = "j",
        stack_save = "n", stack_restore = "o", alloc = "p", malloc = "q" },
    -- 其余是反调试 / 定时器探测：返回 -1（那几个会返回 indexOf 结果）或 0
    probe = function(code)
        if code == 14394 or code == 14449 or code == 14875 then return 0 end
        if code % 709 == 15372 % 709 then return -1 end
        return 0
    end,
    imports = function(env)
        return {
            f = function() return 0 end,
            c = function(a, b) return env.malloc_str(HOST[env.cstr(a) .. "." .. env.cstr(b)] or "undefined") end,
            e = function() return env.malloc_str("undefined") end,
        }
    end,
}

---@param content string base64 密文
---@param chapter_id string|number
---@param keypool string base64 密钥池（fkp 里 onkeyfocus 的第一个参数）
---@param version string
---@param uid string 用户 ywguid
---@return string|nil text
---@return string|nil err
function Fock.decrypt(content, chapter_id, keypool, version, uid)
    return Shared.decrypt(BUILD, content, chapter_id, keypool, version, uid)
end

--- 在子进程里解密；回调拿明文或错误。
---@return BookJob
function Fock.decryptAsync(content, chapter_id, keypool, version, uid, cb)
    return Shared.jobAsync("qidian_fock", function()
        local plain, err = Fock.decrypt(content, chapter_id, keypool, version, uid)
        return { text = plain, err = err }
    end, cb)
end

--- 在子进程里解密并还原 cES=2 的字体层；回调拿纯文本或错误。
--- 起点会在正文尾部追加一份同长度的诱饵副本，restore 的 dedupe 会丢掉它。
---@param info table chapterInfo
---@param fixed_font string fixedFontTtf 下载下来的字节
---@return BookJob
function Fock.chapterAsync(info, fixed_font, chapter_id, keypool, version, uid, cb)
    return Shared.jobAsync("qidian_fock", function()
        local plain, err = Fock.decrypt(info.content, chapter_id, keypool, version, uid)
        if not plain then return { err = "decrypt: " .. tostring(err) } end
        return restore(plain, info, fixed_font)
    end, cb)
end

--- 只有字体层（fEnS=0）时直接还原明文 HTML。
---@param html string Fock 明文或页面正文 HTML
---@param info table chapterInfo
---@param fixed_font string
---@return BookJob
function Fock.restoreAsync(html, info, fixed_font, cb)
    return Shared.jobAsync("qidian_font", function()
        return restore(html, info, fixed_font)
    end, cb)
end

return Fock
