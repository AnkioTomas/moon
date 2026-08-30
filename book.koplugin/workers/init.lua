--[[--
按名字管理 Worker 执行域。

执行域是懒创建的：只有第一次提交请求时才会拉起对应子进程。

@module koplugin.book.workers
--]]

local Runtime = require("workers.runtime")
local Job = require("workers.job")
local definitions = {
    db = require("workers.db"),
}
local instances = {}
local attached = false

local Workers = {
    Protocol = require("workers.protocol"),
    DB = definitions.db,
    Job = Job,
}

---@param name string
---@param definition WorkerDefinition
---@return nil
function Workers.define(name, definition)
    assert(type(name) == "string" and name ~= "", "worker name required")
    assert(type(definition) == "table", "worker definition required")
    assert(type(definition.handlers) == "table", "worker handlers required")
    assert(not instances[name], "worker already created: " .. name)
    definitions[name] = definition
end

---@param name string
---@return WorkerRuntime
function Workers.get(name)
    local worker = instances[name]
    if worker then return worker end
    local definition = definitions[name]
    assert(definition, "unknown worker: " .. tostring(name))
    worker = Runtime.new(definition)
    instances[name] = worker
    if attached then worker:attach() end
    return worker
end

---@param name string
---@return nil
function Workers.destroy(name)
    local worker = instances[name]
    if not worker then return end
    worker:stop()
    instances[name] = nil
end

---@return nil
function Workers.attach()
    attached = true
    for _, worker in pairs(instances) do worker:attach() end
end

---@return nil
function Workers.detach()
    attached = false
    for _, worker in pairs(instances) do worker:detach() end
end

---@return nil
function Workers.stop()
    for _, worker in pairs(instances) do worker:stop() end
    instances = {}
    Job.stop()
    attached = false
end

---@param worker fun(context: table): any
---@param opts WorkerJobOptions|nil
---@return WorkerJob
function Workers.run(worker, opts)
    return Job.run(worker, opts)
end

return Workers
