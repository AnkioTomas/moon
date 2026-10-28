--[[--
QQ阅读已购 VIP 章节正文解密（Fock）：阅文 wasm 的 QQ阅读构建参数 + 子进程编排，宿主在 `source.yuewen_fock`。
结果经导入 b 的回调码 21795 交回。

@module source.qqreader.fock
--]]--

local Shared = require("source.yuewen_fock")
local FontRestore = require("source.yuewen_fonts")

local Fock = {}

local HOST = {
    ["window.location.hostname"] = "book.qq.com",
    ["location.hostname"] = "book.qq.com",
}

---@type YuewenFockBuild
local BUILD = {
    wasm = "source.qqreader.fock_wasm",
    callback = 21795,
    stack = 5274112,
    exports = { ctors = "f", main = "j", set_uid = "g", set_key = "h", decrypt = "i",
        stack_save = "k", stack_restore = "l", alloc = "m", malloc = "n" },
    probe = function(code) return code % 709 == 8 and -1 or 0 end,
    imports = function(env)
        return {
            c = function(ptr) return env.malloc_str(HOST[env.cstr(ptr)] or "undefined") end,
            e = function() return 0 end,
        }
    end,
}

---@param content string base64 密文
---@param chapter_id string|number
---@param keypool string base64 密钥池（piracy 接口 fkp 里 onkeyfocus 的第一个参数）
---@param version string
---@param fuid string piracy 接口给的用户标识
---@return string|nil text
---@return string|nil err
function Fock.decrypt(content, chapter_id, keypool, version, fuid)
    return Shared.decrypt(BUILD, content, chapter_id, keypool, version, fuid)
end

--- 在子进程里解密并还原乱序，回调拿正文纯文本或错误。
--- 起点、潇湘同一套字体反盗版，共用 `source.yuewen_fonts`。
---@param info table /book/read 的 data（content、fontResponse）
---@param fixed_font string|nil fontResponse.fixedFontTtf 下载下来的字节；没有字体加密的章为 nil，不还原字形
---@param chapter_id string|number
---@return BookJob
function Fock.chapterAsync(info, fixed_font, chapter_id, keypool, version, fuid, cb)
    return Shared.jobAsync("qqreader_fock", function()
        local plain, err = Fock.decrypt(info.content, chapter_id, keypool, version, fuid)
        if not plain then return { err = err } end
        local font = type(info.fontResponse) == "table" and info.fontResponse or {}
        return { text = FontRestore.restore(plain, font, fixed_font) }
    end, cb)
end

return Fock
