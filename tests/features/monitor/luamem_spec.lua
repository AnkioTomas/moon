--[[--
monitor.luamem：按模块归属 Lua 堆，共享对象只记给先遍历的一方。
@module tests.features.monitor.luamem_spec
--]]

local Assert = require("support.assert")
local LuaMem = require("features.monitor.luamem")

local shared = { string.rep("x", 4096) }
package.loaded["fakeko.lib"] = { shared = shared }
package.loaded["features.zz.a"] = { shared = shared, own = { string.rep("y", 20000) } }

local rows = LuaMem.scan({ features = true })
local by = {}
for _idx, r in ipairs(rows) do by[r.name] = r end

Assert.is_true(by["KOReader: fakeko"].kb >= 4)
Assert.is_true(by["features.zz"].mine)
Assert.is_true(by["features.zz"].kb >= 19) -- 自己的 20000 字节
Assert.is_true(by["features.zz"].kb < 24) -- 共享的 4096 字节记给 KOReader 一方
Assert.is_true(rows[#rows].rest)

package.loaded["fakeko.lib"], package.loaded["features.zz.a"] = nil, nil
