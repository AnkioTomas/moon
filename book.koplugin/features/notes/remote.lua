--[[--
高亮与笔记的远程管理接口（/api/notes/*，经 web.routes 挂入，不依赖 server）。

  GET  list?page=&q=&source_id=&stable_id=&type=   跨书列表（分页，约 30 条）
  GET  books?page=&q=&type=                        有注解的书（分页，约 30 本）
  GET  item?key=                                   单条详情
  GET  export                                      Markdown 附件（Remote.download）
  POST update {key, note}                          只改备注
  POST remove {key} 或 {keys: [...]}               删除（源侧走墓碑）

GET 只读；有副作用的一律 POST。结果 cb(status, table)：2xx 是数据，4xx/5xx 是 { error = 文案 }。

@module koplugin.book.features.notes.remote
--]]

local Note = require("book.note")
local Query = require("features.notes.query")
local _ = require("gettext")

local Remote = {}

local GET, POST = {}, {}

function GET.list(q, cb)
    cb(200, Query.list(q))
end

function GET.books(q, cb)
    cb(200, Query.books(q))
end

function GET.item(q, cb)
    local item, err = Query.item(q and q.key)
    if not item then
        local status = err == "invalid key" and 400 or 404
        return cb(status, { error = err == "invalid key" and _("无效的条目") or _("找不到这条笔记") })
    end
    cb(200, item)
end

function GET.export(_q, cb)
    -- download() 成功时不会走到这里；失败时给 JSON 错误而不是「接口不存在」。
    cb(500, { error = _("导出失败") })
end

function POST.update(b, cb)
    if type(b) ~= "table" or type(b.key) ~= "string" or b.key == "" then
        return cb(400, { error = _("缺少条目") })
    end
    if b.note ~= nil and type(b.note) ~= "string" then
        return cb(400, { error = _("备注必须是文本") })
    end
    local ok, err = Note.mutate({ key = b.key, note = b.note })
    if not ok then
        local status = err == "not found" and 404 or 400
        return cb(status, { error = err == "not found" and _("找不到这条笔记") or _("保存失败") })
    end
    local item = Query.item(b.key)
    cb(200, item or { ok = true })
end

function POST.remove(b, cb)
    if type(b) ~= "table" then
        return cb(400, { error = _("缺少条目") })
    end
    local keys = b.keys
    if type(keys) ~= "table" then
        keys = b.key and { b.key } or {}
    end
    if #keys == 0 then
        return cb(400, { error = _("缺少条目") })
    end
    local removed, errors = 0, {}
    for _idx, key in ipairs(keys) do
        if type(key) == "string" and key ~= "" then
            local ok, err = Note.mutate({ key = key, remove = true })
            if ok then
                removed = removed + 1
            else
                errors[#errors + 1] = { key = key, error = err }
            end
        end
    end
    if removed == 0 and #errors > 0 then
        local status = errors[1].error == "not found" and 404 or 400
        return cb(status, { error = errors[1].error == "not found" and _("找不到这条笔记") or _("删除失败"), errors = errors })
    end
    cb(200, { ok = true, removed = removed, errors = #errors > 0 and errors or nil })
end

--- 分发；回调只回一次由调用方（remote/ext_route）保证。
---@param method "GET"|"POST"
---@param action string
---@param params table
---@param cb fun(status: integer, result: table)
function Remote.handle(method, action, params, cb)
    local fn = (method == "GET" and GET or POST)[action]
    if not fn then
        return cb(404, { error = _("接口不存在") })
    end
    fn(params or {}, cb)
end

--- 附件下载（GET export）；其余动作返回 nil 交给 handle。
---@param action string
---@return { ctype: string, filename: string, path: string }|nil
function Remote.download(action)
    if action ~= "export" then
        return nil
    end
    local path, err = Query.exportFile()
    if not path then
        return nil
    end
    return {
        ctype = "text/markdown; charset=utf-8",
        filename = "moon-notes.md",
        path = path,
    }
end

return Remote
