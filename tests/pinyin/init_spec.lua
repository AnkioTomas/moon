--[[--
pinyin.init：开关编排（布局 / 候选栏安装 / 词库下载 / 状态文案）

candidate_bar / download / dictionary 全部 stub；只验证编排逻辑：
开关行为、bootstrap 时机、dictStatus 文案。候选合并本身见 candidate_bar_spec。

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
    delSetting = function(_, k)
        saved[k] = nil
    end,
}

-- candidate_bar 假实现：记录 install
local install_calls = 0
local install_opts
package.preload["pinyin.candidate_bar"] = function()
    return {
        install = function(opts)
            install_calls = install_calls + 1
            install_opts = opts
        end,
    }
end

-- download 假实现：记录 ensure 调用
local ensure_calls = 0
local downloading_now = false
package.preload["pinyin.download"] = function()
    return {
        ensure = function(cb)
            ensure_calls = ensure_calls + 1
            if cb then
                cb(true)
            end
        end,
        downloading = function()
            return downloading_now
        end,
    }
end

-- dictionary 假实现：可开关可用性
local dict_available = false
package.preload["pinyin.dictionary"] = function()
    return {
        isAvailable = function()
            return dict_available
        end,
        fileExists = function()
            return false
        end,
        entries = function()
            return "100"
        end,
        sourceTag = function()
            return "test"
        end,
    }
end

local Pinyin = require("pinyin.init")

-- ── bootstrap：关闭时不装候选栏 ───────────────────────
fake_settings.pinyin_enabled = false
Pinyin.bootstrap()
Assert.eq(install_calls, 0, "关闭时 bootstrap 不装候选栏")

-- ── bootstrap：开启后装候选栏，enabled 判定跟随开关 ────
fake_settings.pinyin_enabled = true
Pinyin.bootstrap()
Assert.eq(install_calls, 1)
Assert.is_true(type(install_opts.enabled) == "function")
Assert.is_true(install_opts.enabled(), "enabled 必须读到开启状态")
fake_settings.pinyin_enabled = false
Assert.is_false(install_opts.enabled(), "enabled 必须跟随开关变化")
fake_settings.pinyin_enabled = true

-- ── setEnabled(true)：替代布局 + 装候选栏，不自动下载词库 ──
Assert.is_false(Pinyin.setEnabled(true), "词库不存在时不允许开启")
dict_available = true
saved.keyboard_layouts = { "de", "en", "ru" }
Pinyin.setEnabled(true)
local layouts = saved.keyboard_layouts
Assert.eq(#layouts, 2)
Assert.eq(layouts[1], "en")
Assert.eq(layouts[2], "zh_CN")
Assert.eq(saved.book_pinyin_previous_keyboard_layouts[1], "de")
Assert.eq(saved.book_pinyin_previous_keyboard_layouts[2], "en")
Assert.eq(saved.book_pinyin_previous_keyboard_layouts[3], "ru")
Assert.eq(ensure_calls, 0)
Assert.eq(install_calls, 2)

-- 重复开启仍为相同布局。
local n_layouts = #layouts
Pinyin.setEnabled(true)
Assert.eq(#saved.keyboard_layouts, n_layouts, "布局列表幂等")

-- 关闭不下载、不动布局
Pinyin.setEnabled(false)
Assert.eq(ensure_calls, 0, "开关不应触发下载")
Assert.eq(#saved.keyboard_layouts, 3)
Assert.eq(saved.keyboard_layouts[1], "de")
Assert.eq(saved.keyboard_layouts[2], "en")
Assert.eq(saved.keyboard_layouts[3], "ru")
Assert.is_nil(saved.book_pinyin_previous_keyboard_layouts)

-- ── dictStatus：未下载 / 下载中 / 词条数·tag ──────────
dict_available = false
Assert.eq(Pinyin.dictStatus(), "未下载")
downloading_now = true
Assert.eq(Pinyin.dictStatus(), "下载中…")
downloading_now = false
dict_available = true
Assert.eq(Pinyin.dictStatus(), "100 · test")

Stubs.flush()
