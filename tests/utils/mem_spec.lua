--[[--
utils.mem：重书提醒阈值随可用内存伸缩。

@module tests.utils.mem_spec
--]]

local Assert = require("support.assert")

package.loaded["utils.mem"] = nil
package.loaded["util"] = nil

local free_bytes
package.preload["util"] = function()
    return {
        calcFreeMem = function() return free_bytes end,
    }
end

local Mem = require("utils.mem")
local MB = 1024 * 1024

free_bytes = nil
Assert.eq(Mem.warnThresholdBytes(), 20 * MB)

free_bytes = 20 * MB -- /4 = 5MB → 地板 8MB
Assert.eq(Mem.warnThresholdBytes(), 8 * MB)
Assert.is_true(Mem.isHeavy(8 * MB))
Assert.is_false(Mem.isHeavy(7 * MB))

free_bytes = 80 * MB -- /4 = 20MB
Assert.eq(Mem.warnThresholdBytes(), 20 * MB)

free_bytes = 200 * MB -- /4 = 50MB → 封顶 40MB
Assert.eq(Mem.warnThresholdBytes(), 40 * MB)
Assert.is_false(Mem.isHeavy(39 * MB))
Assert.is_true(Mem.isHeavy(40 * MB))

Assert.eq(Mem.mb(40 * MB), 40)
Assert.eq(Mem.mb(100), 1)
Assert.is_nil(Mem.mb(nil))
