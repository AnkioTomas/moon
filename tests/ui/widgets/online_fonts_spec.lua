--[[--
online_fonts：按在线分类（全部/宋体/黑体/楷体/圆体/其他）展示远程预览图并下载到本地用户字体。

@module tests.ui.widgets.online_fonts_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local image_n = 0
local last_image
local downloaded_map = { ["LXGW.ttf"] = true }
local download_progress, download_cb, download_cancelled
local deleted_files = {}
local set_ui_id
local list_calls = 0
local started_tasks = {}

package.preload["ui/font"] = function()
    return { fontmap = {}, getFace = function(_, id) return { id = id, size = 12 } end }
end
package.loaded["ui/font"] = nil

package.preload["ui.themes.widgets.image"] = function()
    return {
        widget = function(o)
            image_n = image_n + 1
            last_image = o
            return { _src = o.src, getSize = function() return { w = o.width, h = o.height } end,
                paintTo = function() end }
        end,
    }
end

package.preload["ui/network/manager"] = function()
    return { runWhenConnected = function(_, cb) cb() end }
end

package.preload["ui.fonts"] = function()
    return {
        set = function(id) set_ui_id = id; return true end,
        applyCurrent = function() end,
        deleteUserFont = function(filename)
            deleted_files[#deleted_files + 1] = filename
            downloaded_map[filename] = nil
            return true
        end,
    }
end

local sample_items = {
    {
        id = "f1", name = "思源宋体", filename = "Song.ttf", kind = "online",
        category = "song", category_name = "宋体", size = 10485760, size_label = "10.0 MB",
        preview = "https://moon-store.ankio.net/api/v1/store/fonts/f1/preview?mode=name",
        url = "https://moon-store.ankio.net/api/v1/store/fonts/f1/download",
    },
    {
        id = "f2", name = "霞鹜文楷", filename = "LXGW.ttf", kind = "online",
        category = "kai", category_name = "楷体", size = 8388608, size_label = "8.0 MB",
        preview = "https://moon-store.ankio.net/api/v1/store/fonts/f2/preview?mode=name",
        url = "https://moon-store.ankio.net/api/v1/store/fonts/f2/download",
    },
    {
        id = "f3", name = "思源黑体", filename = "Hei.ttf", kind = "online",
        category = "hei", category_name = "黑体", size = 6291456, size_label = "6.0 MB",
        preview = "https://moon-store.ankio.net/api/v1/store/fonts/f3/preview?mode=name",
        url = "https://moon-store.ankio.net/api/v1/store/fonts/f3/download",
    },
}

package.preload["workers.ui.task_dialog"] = function()
    return {
        start = function(spec)
            started_tasks[#started_tasks + 1] = spec
        end,
    }
end
package.loaded["workers.ui.task_dialog"] = nil

package.preload["ui.fonts.catalog"] = function()
    return {
        listOnlineAsync = function(cb, _opts)
            list_calls = list_calls + 1
            cb(sample_items, nil)
            return { cancel = function() end }
        end,
        targetFilename = function(it) return it.filename or (it.id .. ".ttf") end,
        isDownloadedToUser = function(it) return downloaded_map[it.filename] == true end,
        downloadToUserAsync = function(it, progress, cb)
            download_cancelled = false
            download_progress = progress
            download_cb = function(ok, err)
                if ok then downloaded_map[it.filename] = true end
                cb(ok, ok and it.filename or err)
            end
            return { cancel = function() download_cancelled = true end }
        end,
    }
end

package.loaded["ui.widgets.online_fonts"] = nil
local OnlineFonts = require("ui.widgets.online_fonts")

local done_n = 0
OnlineFonts.open{ on_done = function() done_n = done_n + 1 end }

local list = Kit.shown[#Kit.shown]
Assert.eq(list.title, "在线字体")
Assert.eq(list.left_icon, "refresh")

local tab_ids = {}
for _idx, tab in ipairs(list.tabs.tabs) do tab_ids[#tab_ids + 1] = tab.id end
Assert.eq(table.concat(tab_ids, ","), "all,song,hei,kai,yuan,other", "底部按在线分类切栏")
Assert.eq(list.tabs.active, "all")
Assert.len(list.items, 3)
Assert.eq(image_n, 3)
Assert.is_true(last_image.stretch)
Assert.is_true(last_image.invert_in_night)

-- 切到「宋体」分类只看宋体；「圆体」为空显示占位行
list:switchTab("song")
Assert.len(list.items, 1)
Assert.eq(list.items[1].value.id, "f1")
Assert.eq(list.items[1].icon, "download")

list:switchTab("yuan")
Assert.len(list.items, 1)
Assert.is_false(list.items[1].enabled)

-- 下载未下载字体：走可转后台的 TaskDialog.start（kind=download, restartable=true）
list:switchTab("song")
list.items[1].callback()
Assert.len(started_tasks, 1)
local task_spec = started_tasks[1]
Assert.eq(task_spec.key, "font\0Song.ttf")
Assert.eq(task_spec.kind, "download")
Assert.eq(task_spec.title, "思源宋体")
Assert.is_true(task_spec.restartable)

local reports, settled = {}, nil
local handle = task_spec.run(function(text, count, total)
    reports[#reports + 1] = { text = text, count = count, total = total }
end, function(result)
    settled = result
end)
Assert.eq(reports[1].count, 0)
Assert.eq(reports[1].total, 10485760)
download_progress(5242880)
Assert.eq(reports[2].count, 5242880)
Assert.eq(reports[2].total, 10485760)
download_cb(true)
Assert.is_true(settled.ok)
Assert.eq(settled.filename, "Song.ttf")

task_spec.on_done(settled)
Assert.eq(list.items[1].icon, "check_circle", "下载后立刻标为已下载")
Assert.eq(Kit.shown[#Kit.shown].text, "已下载到用户字体：思源宋体")
Assert.eq(done_n, 1)

-- 取消句柄可传透到底层 downloadToUserAsync
handle:cancel()
Assert.is_true(download_cancelled)

-- 失败时弹出错误提示，不触发 on_done
task_spec.on_done({ ok = false, err = "网络超时" })
Assert.eq(Kit.shown[#Kit.shown].text, "网络超时")
Assert.eq(done_n, 1)

-- 已下载字体点按弹出操作菜单：设为界面字体 / 重新下载 / 删除
list:switchTab("kai")
Assert.eq(list.items[1].icon, "check_circle")
list.items[1].callback()
local sheet = Kit.shown[#Kit.shown]
Assert.eq(sheet.items[1].text, "设为界面字体")
Assert.eq(sheet.items[2].text, "重新下载")
Assert.eq(sheet.items[3].text, "删除")
sheet.items[1].callback()
Assert.eq(set_ui_id, "LXGW.ttf")

-- 重新下载同样走后台任务队列
sheet.items[2].callback()
Assert.len(started_tasks, 2)
Assert.eq(started_tasks[2].key, "font\0LXGW.ttf")
Assert.is_true(started_tasks[2].restartable)

-- 删除已下载字体后状态恢复未下载
sheet.items[3].callback()
local confirm = Kit.shown[#Kit.shown]
confirm.ok_callback()
Assert.eq(deleted_files[1], "LXGW.ttf")
Assert.eq(list.items[1].icon, "download")

-- 左上角刷新按钮强制重拉列表
local before_calls = list_calls
list.left_callback()
Assert.eq(list_calls, before_calls + 1)

-- 转后台并关掉在线字体页后任务完成：不再刷新已关闭列表，仍提示完成并回调 on_done
list:switchTab("hei")
list.items[1].callback()
Assert.len(started_tasks, 3)
local bg_spec = started_tasks[3]
local set_items_after_close = 0
local orig_set_items = list.setItems
list.setItems = function(...)
    set_items_after_close = set_items_after_close + 1
    return orig_set_items(...)
end
local before_done = done_n
list:close()
downloaded_map["Hei.ttf"] = true
bg_spec.on_done({ ok = true, filename = "Hei.ttf" })
Assert.eq(set_items_after_close, 0, "列表关闭后后台完成不得刷新已关窗口")
Assert.eq(Kit.shown[#Kit.shown].text, "已下载到用户字体：思源黑体")
Assert.eq(done_n, before_done + 1)

return true
