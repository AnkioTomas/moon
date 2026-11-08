--[[--
远程配置：白名单读写（连接类设置在浏览器填写）。

内置分组与第三方源是同一种表单声明（RemoteSettingForm），网页按快照里的字段声明建表单。
GET 脱敏密钥；POST 是部分更新：缺省的键不动，密钥字段的占位符 "******" 表示不修改。
快照里 `builtin` / `external` 是表单列表；内置分组另按 id 平铺一份键值（`ai`、`moon`…），
提交时内置分组按 id 提交、第三方源放在 `external[源 id]` 下。
全部经 utils.settings 落盘，副作用（registry.invalidate、zlib 清会话、OPDS 重算底栏）与设备设置一致。

@module koplugin.book.features.remote.settings
--]]

local Text = require("utils.text")

local SettingsApi = {}

SettingsApi.MASK = "******"
SettingsApi.BODY_LIMIT = 256 * 1024

---@class RemoteSettingField
---@field key string 配置表里的键
---@field label string
---@field type string|nil 网页输入框类型，缺省 text
---@field placeholder string|nil
---@field secret boolean|nil 读取脱敏、占位符表示不改
---@field normalize nil|fun(value: string): string|nil 缺省去首尾空白

---@class RemoteSettingForm
---@field id string 快照 / 提交里的分组键
---@field name string
---@field fields RemoteSettingField[]
---@field owner string|nil utils.settings 的拥有者分区；缺省是同 id 的源配置（getSource）
---@field invalidate boolean|nil 落盘后作废源实例（连接配置变了）
---@field on_change nil|fun(cfg: table, changed: table<string, boolean>) 字段已改、落盘之前（可改 cfg）
---@field replace nil|fun(changed: table<string, boolean>, save: fun()): boolean|nil 换库：清理成功才 save；nil=不需换库，false=失败
---@field commit nil|fun(cfg: table, values: table<string, string>): boolean 自己落盘，返回有无变化

---@param v string
---@return string
local function raw(v)
    return v
end

-- 网页只有中文，标签不走 gettext。
---@type RemoteSettingForm[]
local BUILTIN = {
    {
        id = "ai", name = "AI 服务", owner = "ai",
        fields = {
            { key = "ai_endpoint", label = "接口地址", type = "url", placeholder = "https://api.example.com/v1",
                normalize = function(v) return Text.rtrimSlashes(Text.trim(v)) end },
            { key = "ai_api_key", label = "API 密钥", secret = true, placeholder = "sk-…" },
            { key = "ai_model", label = "模型", placeholder = "gpt-4o-mini" },
        },
    },
    {
        id = "copymanga", name = "拷贝漫画", invalidate = true,
        fields = {
            { key = "base_url", label = "站点地址", type = "url", normalize = Text.rtrimSlashes },
            { key = "username", label = "账号" },
            { key = "password", label = "密码", secret = true, normalize = raw },
        },
    },
    {
        id = "moon", name = "月读服务", invalidate = true,
        fields = {
            { key = "base_url", label = "服务器地址", type = "url", placeholder = "https://book.example.com",
                normalize = Text.stripWhitespace },
            { key = "token", label = "长期令牌", secret = true, placeholder = "个人Token", normalize = Text.stripWhitespace },
        },
        replace = function(changed, save)
            if changed.base_url or changed.token then
                return require("source.logout").replaceLibrary("moon", save)
            end
        end,
    },
    {
        id = "zlib", name = "Z-Library（下载账号）",
        fields = {
            { key = "email", label = "邮箱", type = "email" },
            { key = "password", label = "密码", secret = true, normalize = raw },
            { key = "base_url", label = "镜像地址（可选）", type = "url", placeholder = "留空自动选择",
                normalize = function(v)
                    v = Text.trim(v)
                    return v ~= "" and v or nil
                end },
        },
        --- 换账号后旧会话作废；只换镜像不用重新登录。
        on_change = function(cfg, changed)
            if changed.email or changed.password then
                cfg.user_id, cfg.user_key = nil, nil
            end
        end,
    },
    {
        id = "opds", name = "OPDS 目录",
        fields = {
            { key = "url", label = "目录地址", type = "url", placeholder = "http://192.168.1.2:8083/opds（留空关闭）" },
            { key = "username", label = "用户名（可选）" },
            { key = "password", label = "密码（可选）", secret = true },
        },
        --- 规范化、清目录缓存都在 store.opds.setting.save；地址空 / 非空决定底栏有没有 OPDS 页签。
        commit = function(cfg, values)
            local function pick(key)
                if values[key] == nil then return cfg[key] end
                return values[key]
            end
            if not require("store.opds.setting").save(pick("url"), pick("username"), pick("password")) then
                return false
            end
            require("source.registry").notifyChanged()
            return true
        end,
    },
    {
        id = "local", name = "本地书库 WebDAV", invalidate = true,
        fields = {
            { key = "webdav_url", label = "WebDAV 地址", type = "url", placeholder = "https://dav.example.com/dav" },
            { key = "webdav_username", label = "用户名" },
            { key = "webdav_password", label = "密码", secret = true },
            { key = "webdav_path", label = "目录" },
        },
        replace = function(changed, save)
            if changed.webdav_url or changed.webdav_path or changed.webdav_username then
                return require("source.logout").replaceWebdav(save)
            end
        end,
    },
}

--- 已在 BUILTIN 里声明的源 id：下面扫 setting.remote 时跳过，避免表单重复。
local BUILTIN_IDS = {}
for _idx, form in ipairs(BUILTIN) do BUILTIN_IDS[form.id] = true end

--- 源设置模块里的 `setting.remote`（第三方扩展 + 内置 kavita/bookorbit）。
--- 可选 `setting.replace_on_remote = { "base_url", ... }`：这些键变了就整源清本地书架。
---@return RemoteSettingForm[]
local function externalForms()
    local Registry = require("source.registry")
    local out = {}
    for _idx, meta in ipairs(Registry.list()) do
        if not BUILTIN_IDS[meta.id] then
            local desc = Registry.external(meta.id)
            local setting = desc and desc.setting
            if not setting then
                local ok, mod = pcall(require, "source." .. meta.id .. ".setting")
                if ok and type(mod) == "table" and mod.remote then setting = mod end
            end
            local fields = setting and setting.remote
            if fields then
                local replace_keys = setting.replace_on_remote
                local replace
                if type(replace_keys) == "table" then
                    replace = function(changed, save)
                        for _k, key in ipairs(replace_keys) do
                            if changed[key] then
                                return require("source.logout").replaceLibrary(meta.id, save)
                            end
                        end
                    end
                end
                out[#out + 1] = {
                    id = meta.id, name = meta.name, fields = fields,
                    invalidate = true, replace = replace,
                }
            end
        end
    end
    return out
end

---@param form RemoteSettingForm
---@return table
local function load(form)
    local Settings = require("utils.settings")
    if form.owner then return Settings.get(form.owner) end
    return Settings.getSource(form.id)
end

---@param form RemoteSettingForm
---@param cfg table
local function store(form, cfg)
    local Settings = require("utils.settings")
    if form.owner then
        Settings.save(form.owner, cfg)
    else
        Settings.saveSource(form.id, cfg)
    end
end

--- 表单快照：网页用的字段声明（密钥脱敏，normalize 不下发）+ 平铺的键值。
---@param form RemoteSettingForm
---@return table form_snapshot
---@return table<string, string> values
local function snapshotForm(form)
    local cfg = load(form)
    local fields, values = {}, {}
    for idx, field in ipairs(form.fields) do
        local value = cfg[field.key]
        if field.secret then
            value = (value == nil or value == "") and "" or SettingsApi.MASK
        else
            value = value == nil and "" or tostring(value)
        end
        values[field.key] = value
        fields[idx] = {
            key = field.key,
            label = field.label,
            type = field.secret and "password" or field.type or "text",
            placeholder = field.placeholder or "",
            value = value,
        }
    end
    return { id = form.id, name = form.name, fields = fields }, values
end

--- 部分更新一张表单：只认声明过的键，缺省键与密钥占位符不动。
---@param form RemoteSettingForm
---@param incoming table 网页提交的键值
---@return boolean|nil changed
---@return string|nil err
local function applyForm(form, incoming)
    local cfg = load(form)
    local values = {}
    for _idx, field in ipairs(form.fields) do
        local v = incoming[field.key]
        if v ~= nil and not (field.secret and v == SettingsApi.MASK) then
            values[field.key] = tostring(v)
        end
    end
    if form.commit then return form.commit(cfg, values) end
    local changed, normalized = {}, {}
    for _idx, field in ipairs(form.fields) do
        local v = values[field.key]
        if v ~= nil then
            local value = (field.normalize or Text.trim)(v)
            if cfg[field.key] ~= value then
                normalized[field.key] = value
                changed[field.key] = true
            end
        end
    end
    if next(changed) == nil then return false end
    local function save()
        for key in pairs(changed) do cfg[key] = normalized[key] end
        if form.on_change then form.on_change(cfg, changed) end
        store(form, cfg)
    end
    local replaced = form.replace and form.replace(changed, save)
    if replaced == false then return nil, "清除本地记录失败" end
    if not replaced then
        save()
        if form.invalidate then require("source.registry").invalidate() end
    end
    return true
end

---@return table
function SettingsApi.snapshot()
    local out = { builtin = {}, external = {} }
    for idx, form in ipairs(BUILTIN) do
        local snapshot, values = snapshotForm(form)
        out.builtin[idx] = snapshot
        out[form.id] = values
    end
    for idx, form in ipairs(externalForms()) do
        out.external[idx] = (snapshotForm(form))
    end
    return out
end

---@param payload table
---@return table|nil result
---@return string|nil err
function SettingsApi.apply(payload)
    if type(payload) ~= "table" then
        return nil, "invalid json"
    end
    local changed = false
    for _idx, form in ipairs(BUILTIN) do
        if type(payload[form.id]) == "table" then
            local applied, err = applyForm(form, payload[form.id])
            if applied == nil then return nil, err end
            changed = applied or changed
        end
    end
    if type(payload.external) == "table" then
        for _idx, form in ipairs(externalForms()) do
            if type(payload.external[form.id]) == "table" then
                local applied, err = applyForm(form, payload.external[form.id])
                if applied == nil then return nil, err end
                changed = applied or changed
            end
        end
    end
    return { ok = true, changed = changed, settings = SettingsApi.snapshot() }
end

return SettingsApi
