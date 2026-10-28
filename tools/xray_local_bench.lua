--[[--
本地 AI 上跑 X-Ray 全书分析计时（不经 SDL 模拟器）。
用法（仓库根）：
  KO_HOME=.../emu-home luajit tools/xray_local_bench.lua [正文txt]

用 curl 打 OpenAI 兼容接口，避开模拟器里 LuaSocket×macOS Network 的 SIGSEGV。
--]]

local ROOT = arg[0]:match("(.+)/tools/xray_local_bench%.lua$") or "."
local BOOK = arg[1] or (os.getenv("HOME") .. "/Documents/SourceCode/LUA/emu-home/books/xray_sample.txt")
local ENDPOINT = os.getenv("AI_ENDPOINT") or "http://127.0.0.1:8000/v1/chat/completions"
local MODEL = os.getenv("AI_MODEL") or "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"
local KEY = os.getenv("AI_API_KEY") or "local"

package.path = table.concat({
    ROOT .. "/book.koplugin/?.lua",
    ROOT .. "/book.koplugin/?/init.lua",
    ROOT .. "/tests/?.lua",
    package.path,
}, ";")

-- 最小 stub：只够 load features.xray.fetch
package.preload["gettext"] = function() return function(s) return s end end
package.preload["l10n"] = function() return { apply = function() end, catalog = function() return "zh_CN" end } end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.preload["logger"] = function()
    return { dbg = function() end, info = print, warn = print, err = print }
end
package.preload["utils.log"] = function() return require("logger") end
package.preload["json"] = function()
    return require("support.json_stub")
end
package.preload["utils.settings"] = function()
    return {
        get = function()
            return {
                book_xray_quality = "standard",
                ai_endpoint = ENDPOINT,
                ai_api_key = KEY,
                ai_model = MODEL,
                ai_provider = "vllm",
                ai_language = "zh_CN",
                ai_timeout = 180,
            }
        end,
        save = function() end,
    }
end
package.preload["http.timeout"] = function()
    return { ai = function(r) return 180 * (r or 1) end, aiSeconds = function() return 180 end }
end
package.preload["reader.session"] = function()
    return { current = function() return { percent = 1 } end, chapterIndex = function() return nil end }
end
package.preload["reader.context"] = function() return {} end
package.preload["features.xray.marks"] = function() return { invalidate = function() end } end

local entity_rows, scan_cursor = {}, nil
package.preload["features.xray.db"] = function()
    return {
        list = function()
            local out = {}
            for i, row in ipairs(entity_rows) do out[i] = row end
            return out
        end,
        removedSet = function() return {} end,
        restore = function() end,
        replace = function(_, _, entities)
            entity_rows = {}
            for i, e in ipairs(entities) do entity_rows[i] = e end
            return true
        end,
        scanCursor = function() return scan_cursor end,
        saveScanCursor = function(_, _, digest, done, total)
            scan_cursor = { digest = digest, done = done, total = total }
            return true
        end,
        clearScanCursor = function() scan_cursor = nil; return true end,
    }
end

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function now_ms()
    local pipe = io.popen("python3 -c 'import time; print(int(time.time()*1000))'", "r")
    local n = pipe and tonumber(pipe:read("*a")) or 0
    if pipe then pipe:close() end
    return n
end

local function curl_chat(messages, max_tokens)
    local Json = require("support.json_stub")
    local payload = Json.encode({
        model = MODEL,
        messages = messages,
        temperature = 0.2,
        max_tokens = max_tokens or 10000,
        chat_template_kwargs = { enable_thinking = false },
        enable_thinking = false,
    })
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, "wb"))
    f:write(payload)
    f:close()
    local cmd = string.format(
        "curl -sS -m 180 -X POST %s -H %s -H %s --data-binary @%s",
        shell_quote(ENDPOINT),
        shell_quote("Content-Type: application/json"),
        shell_quote("Authorization: Bearer " .. KEY),
        shell_quote(tmp)
    )
    local t0 = now_ms()
    local pipe = io.popen(cmd, "r")
    local body = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    local ms = now_ms() - t0
    os.remove(tmp)
    local ok, decoded = pcall(Json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return nil, "bad json: " .. body:sub(1, 200), ms
    end
    local choice = decoded.choices and decoded.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) ~= "string" or content == "" then
        return nil, "empty content finish=" .. tostring(choice and choice.finish_reason) .. " body=" .. body:sub(1, 200), ms
    end
    content = content:gsub("^```[%w_%-]*%s*", ""):gsub("%s*```$", "")
    local parsed_ok, parsed = pcall(Json.decode, content)
    if not parsed_ok then
        local first = content:find("{", 1, true)
        local last = content:match(".*()}")
        if first and last and last >= first then
            parsed_ok, parsed = pcall(Json.decode, content:sub(first, last))
        end
    end
    if not parsed_ok or type(parsed) ~= "table" then
        return nil, "not object: " .. content:sub(1, 200), ms
    end
    return parsed, nil, ms
end

-- 把 AI.jsonExtract 换成 curl
package.preload["ai"] = function()
    return {
        isConfigured = function() return true end,
        priorSummaries = function() return nil end,
        jsonExtract = function(messages, opts, cb)
            local decoded, err, ms = curl_chat(messages, opts and opts.max_tokens)
            _G.__bench_last_ms = ms
            cb(decoded, err)
            return { cancel = function() end }
        end,
    }
end

local Fetch = require("features.xray.fetch")
local identity = {
    source_id = "local",
    stable_id = BOOK,
    book = { title = "边城（样本）", authors = "沈从文" },
}

local f = assert(io.open(BOOK, "rb"))
local size = f:seek("end") or 0
f:close()
local bounds, len_or_err = Fetch.chunkBounds(BOOK, 12000)
assert(bounds, tostring(len_or_err))
print(string.format("FILE %s bytes=%d chunks=%d digest=%s", BOOK, size, #bounds, tostring(len_or_err) .. ":" .. #bounds))

local reports = {}
local t_start = now_ms()
local done_result
local run = Fetch.scanBook(identity, BOOK)
run(function(text, count, total)
    local ms = _G.__bench_last_ms
    reports[#reports + 1] = { text = text, count = count, total = total, chunk_ms = ms }
    print(string.format("PROGRESS %s %s/%s last_chunk_ms=%s", tostring(text), tostring(count), tostring(total), tostring(ms)))
end, function(result)
    done_result = result
end)

local wall = now_ms() - t_start
local chars, locs, terms = 0, 0, 0
for _, row in ipairs(entity_rows) do
    if row.kind == "character" then chars = chars + 1
    elseif row.kind == "location" then locs = locs + 1
    elseif row.kind == "term" then terms = terms + 1 end
end

print("---- RESULT ----")
print(string.format("ok=%s progressed=%s err=%s", tostring(done_result and done_result.ok), tostring(done_result and done_result.progressed), tostring(done_result and done_result.err)))
print(string.format("wall_ms=%d chunks=%d entities char=%d loc=%d term=%d", wall, #bounds, chars, locs, terms))
for i, row in ipairs(entity_rows) do
    print(string.format("  [%s] %s", row.kind, row.name))
    if i >= 20 then print("  ..."); break end
end
local sum = 0
for _, r in ipairs(reports) do sum = sum + (r.chunk_ms or 0) end
print(string.format("sum_chunk_ms=%d avg_chunk_ms=%d", sum, #bounds > 0 and math.floor(sum / #bounds) or 0))
if not (done_result and done_result.ok) then os.exit(1) end
