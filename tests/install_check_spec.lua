--[[-- 安装完整性自检：对照 manifest.txt，缺模块返回排序后的缺失清单；没有 manifest（开发树）不检查。 @module tests.install_check_spec --]]

local Assert = require("support.assert")
local Check = require("install_check")

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local index = { ["desktop"] = "x", ["utils/text"] = "y" }

Assert.is_nil(Check.check(dir, index), "没有 manifest 不检查")

local f = io.open(dir .. "/manifest.txt", "w")
f:write("desktop\nutils/text\n")
f:close()
Assert.is_nil(Check.check(dir, index), "齐全放行")
Assert.is_nil(Check.check(dir, { desktop = "x", ["utils/text"] = "y", stale = "z" }), "多出旧文件不拦")

f = io.open(dir .. "/manifest.txt", "w")
f:write("desktop\ndesktop/pages/home\nutils/text\ndesktop/pages/library\n")
f:close()
local missing = Check.check(dir, index)
Assert.eq(table.concat(missing, ","), "desktop/pages/home,desktop/pages/library")
os.execute("rm -rf '" .. dir .. "'")

return true
