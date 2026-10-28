--[[--
潇湘 VIP 章节正文解密（Fock）：阅文 wasm 的潇湘构建参数 + 子进程编排，宿主在 `source.yuewen_fock`。
网页端用它解密 `chapterContents[].chapterContent`。

@module source.xiaoxiang.fock
--]]--

local Shared = require("source.yuewen_fock")

local Fock = {}

local HOST = {
    ["location.hostname"] = "www.xxsypro.com",
    ["location.protocol"] = "https:",
}

---@type YuewenFockBuild
local BUILD = {
    wasm = "source.xiaoxiang.fock_wasm",
    callback = 22353,
    stack = 5274656,
    exports = { ctors = "g", main = "l", set_uid = "h", set_key = "i", decrypt = "j",
        stack_save = "m", stack_restore = "n", alloc = "o", malloc = "p" },
    -- 其余是反调试 / 定时器探测：返回 -1（那几个会返回 indexOf 结果）或 0
    probe = function(code) return code % 709 == 151 and -1 or 0 end,
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
---@param uid string 用户 ywGuid
---@return string|nil text
---@return string|nil err
function Fock.decrypt(content, chapter_id, keypool, version, uid)
    return Shared.decrypt(BUILD, content, chapter_id, keypool, version, uid)
end

--- 在子进程里解密并还原乱序字体，回调拿正文纯文本或错误。
---@param info table chapterContents 的一项（chapterContent、fontResponse）
---@param fixed_font string|nil fontResponse.fixedFontTtf 下载下来的字节；没有字体加密的章为 nil
---@return BookJob
function Fock.chapterAsync(info, fixed_font, chapter_id, keypool, version, uid, cb)
    return Shared.jobAsync("xiaoxiang_fock", function()
        local plain, err = Fock.decrypt(info.chapterContent, chapter_id, keypool, version, uid)
        if not plain then return { err = err } end
        local font = type(info.fontResponse) == "table" and info.fontResponse or {}
        return { text = require("source.yuewen_fonts").restore(plain, font, fixed_font) }
    end, cb)
end

return Fock
