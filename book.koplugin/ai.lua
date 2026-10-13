--[[--
可复用 AI 能力门面：chat / jsonExtract，以及给提示词用的前文章节摘要 priorSummaries。

其它模块统一 require("ai")，不要直连 client。

@module koplugin.book.ai
--]]

local AiJson = require("ai.json")
local Client = require("ai.client")

local AI = {}

--- AI 端点、密钥、模型是否已配置齐全。
AI.isConfigured = Client.isConfigured

--- 非流式聊天；cb(content, err)。
---@param messages table[]
---@param opts table|nil
---@param cb fun(content: string|nil, err: any)
---@return table|nil
function AI.chat(messages, opts, cb)
    if type(opts) == "function" then
        cb = opts
        opts = nil
    end
    return Client.chat(messages, opts, cb)
end

--- 当前章之前最近 chapters 章的 AI 摘要（ai.summary_db），按章序拼成「章名\n摘要」段落；一章都没有返回 nil。
--- 只取当前章之前：当前章可能是回翻来的，它的摘要会剧透本章后半段。
---@param identity BookIdentity
---@param current_idx integer 当前目录章序号
---@param chapters integer
---@return string|nil
function AI.priorSummaries(identity, current_idx, chapters)
    local rows = require("ai.summary_db").upTo(identity.source_id, identity.stable_id, current_idx - 1, chapters)
    if #rows == 0 then return nil end
    local parts = {}
    for _idx, row in ipairs(rows) do
        parts[#parts + 1] = (row.title ~= "" and row.title or ("#" .. row.chapter_idx)) .. "\n" .. row.summary
    end
    return table.concat(parts, "\n\n")
end

--- 非流式 JSON 抽取；cb(table|nil, err)。
---@param messages table[]
---@param opts table|nil
---@param cb fun(result: table|nil, err: any)
---@return table|nil
function AI.jsonExtract(messages, opts, cb)
    if type(opts) == "function" then
        cb = opts
        opts = nil
    end
    return Client.chat(messages, opts, function(content, err)
        if not content then
            cb(nil, err)
            return
        end
        local result, decode_err = AiJson.decode(content)
        cb(result, decode_err)
    end)
end

return AI
