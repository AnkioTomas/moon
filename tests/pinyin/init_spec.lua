--[[--
pinyin.init：IME hook 候选合并 / 开关编排

generic_ime 用 package.preload 注入假原型表；dictionary 用假查询；
只验证 hook 合并顺序、zh_CN 实例过滤、词库降级透传、setEnabled 触发下载。

@module tests.pinyin.init_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

-- settings 内存 mock
local fake_settings = {}
package.preload["utils.settings"] = function()
    return {
        get = function()
            return fake_settings
        end,
        save = function() end,
    }
end

-- G_reader_settings（ensureLayouts 用）
local saved = {}
_G.G_reader_settings = {
    readSetting = function(_, k, default)
        return saved[k] ~= nil and saved[k] or default
    end,
    saveSetting = function(_, k, v)
        saved[k] = v
    end,
}

-- dictionary 假实现：可开关可用性、固定词表
local dict_available = true
local dict_words = {}
package.preload["pinyin.dictionary"] = function()
    return {
        isAvailable = function()
            return dict_available
        end,
        lookup = function(code)
            return dict_words[code] or {}
        end,
        entries = function()
            return "100"
        end,
        sourceTag = function()
            return "test"
        end,
    }
end

-- download 假实现：记录 ensure 调用
local ensure_calls = 0
package.preload["pinyin.download"] = function()
    return {
        ensure = function(cb)
            ensure_calls = ensure_calls + 1
            if cb then
                cb(true)
            end
        end,
        downloading = function()
            return false
        end,
    }
end

-- generic_ime 假原型：getCandiFromMap 返回原生单字
local IME = {}
function IME.getCandiFromMap(self, code)
    return self._native[code]
end
package.preload["ui/data/keyboardlayouts/generic_ime"] = function()
    return IME
end

local Pinyin = require("pinyin.init")

-- ── hook 未装前：原生透传 ─────────────────────────────
local zh = { switch_char = "→", switch_char_prev = "←", _native = { ni = { "你", "呢" } } }
Assert.eq(IME.getCandiFromMap(zh, "ni")[1], "你")

-- ── bootstrap：开启后才装 hook ────────────────────────
fake_settings.pinyin_enabled = false
Pinyin.bootstrap()
dict_words.ni = { "你好", "年级" }
Assert.eq(IME.getCandiFromMap(zh, "ni")[1], "你") -- 未装 hook，仍原生

fake_settings.pinyin_enabled = true
Pinyin.bootstrap()
-- 词库整词在前，原生单字在后，去重
local merged = IME.getCandiFromMap(zh, "ni")
Assert.eq(merged[1], "你好")
Assert.eq(merged[2], "年级")
Assert.eq(merged[3], "你")
Assert.eq(merged[4], "呢")
Assert.len(merged, 4)

-- 词库无结果 → 原生
dict_words.ni = nil
local r = IME.getCandiFromMap(zh, "ni")
Assert.eq(r[1], "你")
Assert.len(r, 2)

-- 词库不可用 → 原生透传
dict_words.ni = { "你好" }
dict_available = false
r = IME.getCandiFromMap(zh, "ni")
Assert.eq(r[1], "你")
Assert.len(r, 2)
dict_available = true

-- 非 zh_CN 实例（ja 布局共用原型，switch_char 不同）→ 零影响
local ja = { switch_char = "↔", switch_char_prev = "↔", _native = { ni = { "に" } } }
r = IME.getCandiFromMap(ja, "ni")
Assert.eq(r[1], "に")
Assert.len(r, 1)

-- 非纯字母码 → 透传
r = IME.getCandiFromMap(zh, "ni3")
Assert.is_nil(r) -- 原生 _native 无此键

-- ── setEnabled(true)：补布局 + 触发词库下载 ──────────
ensure_calls = 0
Pinyin.setEnabled(true)
local layouts = saved.keyboard_layouts
local have = {}
for _, l in ipairs(layouts) do
    have[l] = true
end
Assert.is_true(have.en)
Assert.is_true(have.zh_CN)
Assert.eq(ensure_calls, 1)

-- 关闭不下载、不动布局
Pinyin.setEnabled(false)
Assert.eq(ensure_calls, 1)

Stubs.flush()
