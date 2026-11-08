--[[--
盐选字体：只改文本节点、不能缓存未还原的乱码，所有退出路径清理临时文件。

@module tests.source.zhihu.font_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Config = require("support.config")
local Text = require("utils.text")
local Glyph = require("utils.glyph")
local lfs = require("libs/libkoreader-lfs")
local root = Config.dir() .. "/zhihu-font-fixture"
lfs.mkdir(root)
lfs.mkdir(root .. "/noto")
local reference_path = root .. "/noto/NotoSansCJKsc-Regular.otf"
local reference = assert(io.open(reference_path, "wb"))
reference:write("reference")
reference:close()
package.preload["fontlist"] = function() return { fontdir = root } end

---@type table<integer, string|false>
local map = { [0x7684] = "正", [0x4E0D] = "全", [0x4E86] = "。" }
local tmp_path, options, pending, fail_worker
local original_tmpname = os.tmpname
os.tmpname = function()
    tmp_path = original_tmpname()
    return tmp_path
end
Glyph.recognize = function(ref, _cache, tasks)
    Assert.eq(ref, reference_path)
    Assert.eq(tasks[1].font_path, tmp_path)
    local file = assert(io.open(tmp_path, "rb"))
    Assert.eq(file:read("*a"), "\0\1\0\0fixture")
    file:close()
    Assert.contains(tasks[1].codes, 0x4E86, "数字实体也必须参与识别")
    return { map }
end
package.preload["workers.job"] = function()
    return { run = function(worker, opts)
        options = opts
        if not pending then
            local ok, result = pcall(worker)
            if not ok then opts.on_failed(result)
            elseif fail_worker then opts.on_failed("worker failed")
            else opts.on_done(result) end
        end
        local job = {}
        function job:cancel() opts.on_cancelled() end
        return job
    end }
end

local Font = require("source.zhihu.font")
local wire = {
    manuscript = '的<p title="的">不&amp;&#x4E86;<b>的</b><img src="https://img/的.png"/>&lt;的&gt;</p>了',
    font = { base64 = "data:font/ttf;charset=utf-8;base64," .. Text.base64Encode("\0\1\0\0fixture") },
}
local html, message, completed
local function run()
    html, message, completed = nil, nil, 0
    return Font.restoreAsync(wire, function(value, err)
        html, message = value, err
        completed = completed + 1
    end)
end
run()
Assert.eq(html, '正<p title="的">全&amp;。<b>正</b><img src="https://img/的.png"/>&lt;正&gt;</p>。')
Assert.is_nil(message)
Assert.eq(options.kind, "light", "字形识别不能阻塞 UI")
Assert.is_nil(io.open(tmp_path, "rb"), "成功后清理字体")

map[0x4E86] = false
run()
Assert.is_nil(html)
Assert.eq(message, "知乎章节字体还原失败，请重试")
Assert.is_nil(io.open(tmp_path, "rb"))
map[0x4E86] = "。"
wire.font.base64 = "data:font/ttf;charset=utf-8;base64," .. Text.base64Encode("<html>error</html>")
run()
Assert.is_nil(html)
Assert.eq(message, "知乎章节字体还原失败，请重试")
Assert.is_nil(io.open(tmp_path, "rb"))

wire.font.base64 = "data:font/ttf;charset=utf-8;base64," .. Text.base64Encode("\0\1\0\0fixture")
fail_worker = true
run()
Assert.eq(message, "worker failed")
Assert.is_nil(io.open(tmp_path, "rb"), "任务失败后清理字体")
pending = true
local handle = run()
local file = assert(io.open(tmp_path, "wb"))
file:write("pending")
file:close()
handle:cancel()
Assert.eq(completed, 0, "取消时不交付正文")
Assert.is_nil(io.open(tmp_path, "rb"), "取消后清理字体")
os.tmpname = original_tmpname
os.remove(reference_path)
os.remove(root .. "/noto")
os.remove(root)
