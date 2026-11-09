--[[--
system 模式下的字段例外：路由与 Android 后端共用同一份判定。

- `usesBuiltin`：数字 / 密码字段必须走内置键盘（数字层、遮罩，系统 IME 看不到明文）。
- `isReadonly`：只读字段本来没有键盘，路由直接不弹任何键盘。

@module koplugin.book.features.ime.field
--]]

local Field = {}

--- 该字段是否必须交给内置键盘。
---@param inputbox table|nil
---@return boolean
function Field.usesBuiltin(inputbox)
    if type(inputbox) ~= "table" then return false end
    if inputbox.input_type == "number" then return true end
    if inputbox.text_type == "password" then return true end
    if inputbox.is_password_type == true then return true end
    return false
end

--- 只读字段：不弹键盘。
---@param inputbox table|nil
---@return boolean
function Field.isReadonly(inputbox)
    return type(inputbox) == "table" and inputbox.readonly == true
end

return Field
