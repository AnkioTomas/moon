--[[--
月读同步里的书籍附属数据：AI 摘要、X-Ray 这类花 AI 额度生成、换设备重做很贵的东西。

一个提供者、一本书一份：`.moon-koreader/extra/<提供者>/<源>/<文件名>.json` = `{ updated_at, data }`。
提供者是核心的 AI 摘要，加上挂点 `sync.book_data` 登记的。本机记每份上次同步时的哈希和远端修改时间
（缓存目录 moon_sync_extra），据此决定推、拉还是跳过：

  - 只本地变了推，只远端变了拉。本地清空过也算变了，推一份空快照，别的设备拉到就清空。
  - 两边都变了：merge 提供者先拉（并集）再推；其余比 updated_at，后写的整本赢。
  - 远端清单不可信（更旧或分叉）时，非 merge 提供者只推不拉。

只处理本机书库里有行的书：别的设备独有的书，等它进了本机书库再拉。

@module koplugin.book.moon_sync.extra
--]]

local Extra = {}

local SEEN = "moon_sync_extra"

---@class BookSyncDataProvider
---@field id string
---@field merge boolean|nil
---@field books fun(): { source_id: string, stable_id: string }[]
---@field export fun(source_id: string, stable_id: string): table|nil, integer
---@field import fun(source_id: string, stable_id: string, data: table): boolean

--- 核心的 AI 摘要在前，挂点登记的在后。
---@return BookSyncDataProvider[]
function Extra.providers()
    local list = {
        {
            id = "summary",
            merge = true,
            books = function() return require("ai.summary_db").books() end,
            export = function(source_id, stable_id) return require("ai.summary_db").export(source_id, stable_id) end,
            import = function(source_id, stable_id, data)
                return require("ai.summary_db").import(source_id, stable_id, data)
            end,
        },
    }
    for _idx, item in ipairs(require("utils.extension").list("sync.book_data")) do list[#list + 1] = item end
    return list
end

--- 快照指纹；没数据是空串。data 只含数组，同样内容编码相同。
---@param data table|nil
---@return string
function Extra.hash(data)
    if data == nil then return "" end
    return require("ffi/sha2").md5(require("json").encode(data)) --[[@as string]]
end

--- 推、拉、两边都变（both），或不动。
---@param spec { seen: { hash: string, mtime: number|nil }|nil, hash: string, remote_mtime: number|nil, merge: boolean|nil, trusted: boolean }
---@return "push"|"pull"|"both"|"skip"
function Extra.action(spec)
    local seen = spec.seen
    local local_changed = (seen and seen.hash or "") ~= spec.hash
    local remote_changed = spec.remote_mtime ~= nil and (seen == nil or seen.mtime ~= spec.remote_mtime)
    if not spec.trusted and not spec.merge then remote_changed = false end
    if local_changed and remote_changed then return "both" end
    if remote_changed then return "pull" end
    if local_changed then return "push" end
    return "skip"
end

---@return table<string, { hash: string, mtime: number|nil }>
function Extra.loadSeen()
    local raw = require("utils.fs").read(require("utils.paths").cacheDir() .. "/" .. SEEN)
    if type(raw) ~= "string" or raw == "" then return {} end
    local ok, doc = pcall(require("json").decode, raw)
    if not ok or type(doc) ~= "table" then return {} end
    return doc
end

---@param seen table
function Extra.saveSeen(seen)
    local Paths = require("utils.paths")
    if not Paths.ensureDir(Paths.cacheDir()) then return end
    local file = io.open(Paths.cacheDir() .. "/" .. SEEN, "wb")
    if not file then return end
    file:write(require("json").encode(seen))
    file:close()
end

return Extra
