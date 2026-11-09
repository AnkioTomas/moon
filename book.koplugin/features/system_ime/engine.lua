--[[--
Android JNI 桥：加载 koboard dex，构造 show / hide / sync 与快照读取。

只在 Android 上被 `features.system_ime` 惰性 require；桌面 / 离线测试不加载。
dex 的校验与安装见同级 dex.lua，本模块只负责 JNI 与文件快照。

@module koplugin.book.features.system_ime.engine
--]]

local Dex = require("features.system_ime.dex")

local Engine = {}

--- 与 koboard v0.6.5 构建产物一致；发布物由 CI 校验。
local DEX_SHA256 = "6129e4f3acde998617224e9291690b151e1aeffdf4960087fb45210b35e5d1e2"

local function warn(...)
    local ok, logger = pcall(require, "utils.log")
    if ok and type(logger) == "table" and type(logger.warn) == "function" then
        logger.warn(...)
    end
end

--- 调用 Activity 上的无参 / 单字符串方法并取 File.getAbsolutePath()。
---@param android table
---@param getter string
---@param signature string
---@param arg string|nil
---@return string|nil
local function callFilePath(android, getter, signature, arg)
    local ffi = require("ffi")
    local activity = android.app and android.app.activity
    if not (activity and activity.vm and activity.clazz and android.jni) then
        return nil
    end
    local jvm, act = activity.vm, activity.clazz
    local result
    android.jni:context(jvm, function(jni)
        local env = jni.env
        local method = env[0].GetMethodID(env, env[0].GetObjectClass(env, act), getter, signature)
        if method == nil then return end
        local file = env[0].CallObjectMethod(env, act, method,
            arg and ffi.new("char[?]", #arg + 1, arg) or nil)
        if file == nil then return end
        local path_method = env[0].GetMethodID(env, env[0].GetObjectClass(env, file),
            "getAbsolutePath", "()Ljava/lang/String;")
        local jp = env[0].CallObjectMethod(env, file, path_method)
        local utf = env[0].GetStringUTFChars(env, jp, nil)
        result = ffi.string(utf)
        env[0].ReleaseStringUTFChars(env, jp, utf)
        env[0].DeleteLocalRef(env, jp)
        env[0].DeleteLocalRef(env, file)
    end)
    return result
end

--- 用 DexClassLoader 加载已知类 org.koreader.koboard.KOBoardShow。
---@param android table
---@param dex_path string
---@param opt_dir string
---@return userdata|nil class
---@return string|nil err
local function loadClass(android, dex_path, opt_dir)
    pcall(os.execute, "rm -rf " .. ("'" .. opt_dir:gsub("'", "'\\''") .. "'")
        .. " && mkdir -p " .. ("'" .. opt_dir:gsub("'", "'\\''") .. "'"))

    local jvm = android.app.activity.vm
    local act = android.app.activity.clazz
    local ok, cls = pcall(function()
        return android.jni:context(jvm, function(jni)
            local env = jni.env
            local function jstr(s) return env[0].NewStringUTF(env, s) end

            local dcl_cls = env[0].FindClass(env, "dalvik/system/DexClassLoader")
            if dcl_cls == nil then return nil end
            local dcl_ctor = env[0].GetMethodID(env, dcl_cls, "<init>",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
            local cl_mid = env[0].GetMethodID(env, env[0].GetObjectClass(env, act),
                "getClassLoader", "()Ljava/lang/ClassLoader;")
            local parent = env[0].CallObjectMethod(env, act, cl_mid)

            local jd, jo = jstr(dex_path), jstr(opt_dir)
            local dcl = env[0].NewObject(env, dcl_cls, dcl_ctor, jd, jo, nil, parent)
            env[0].DeleteLocalRef(env, jd)
            env[0].DeleteLocalRef(env, jo)
            env[0].DeleteLocalRef(env, parent)
            if dcl == nil then return nil end

            local load_mid = env[0].GetMethodID(env, env[0].GetObjectClass(env, dcl),
                "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
            local jn = jstr("org.koreader.koboard.KOBoardShow")
            local loaded = env[0].CallObjectMethod(env, dcl, load_mid, jn)
            env[0].DeleteLocalRef(env, jn)
            env[0].DeleteLocalRef(env, dcl)
            if loaded == nil then return nil end
            return env[0].NewGlobalRef(env, loaded)
        end)
    end)
    if not ok then return nil, "dex load failed: " .. tostring(cls) end
    if not cls then return nil, "dex load failed" end
    return cls
end

--- 构造 JNI 调用与快照路径。
---@param android table
---@param dex_class userdata
---@param ext_dir string
---@return table|nil engine
---@return string|nil err
local function makeEngine(android, dex_class, ext_dir)
    local ffi = require("ffi")
    local jvm = android.app.activity.vm
    local act = android.app.activity.clazz
    local paths = {
        input = ext_dir .. "/koboard_input",
        snapshot = ext_dir .. "/koboard_input.processing",
        backspace = ext_dir .. "/koboard_bs",
        height = ext_dir .. "/koboard_height",
    }

    local function jstr(env, s) return env[0].NewStringUTF(env, s or "") end

    local function show(text, sel_start, sel_end)
        android.jni:context(jvm, function(jni)
            local env = jni.env
            local svc = jstr(env, "input_method")
            local imm = jni:callObjectMethod(act, "getSystemService",
                "(Ljava/lang/String;)Ljava/lang/Object;", svc)
            env[0].DeleteLocalRef(env, svc)

            local ext_file = env[0].CallObjectMethod(env, act,
                env[0].GetMethodID(env, env[0].GetObjectClass(env, act),
                    "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;"), nil)
            local editor_text = jstr(env, text or "")
            local ctor = env[0].GetMethodID(env, dex_class, "<init>",
                "(Landroid/view/inputmethod/InputMethodManager;Landroid/app/Activity;Ljava/io/File;Ljava/lang/String;II)V")
            local shower = env[0].NewObject(env, dex_class, ctor, imm, act, ext_file, editor_text,
                ffi.cast("jint", sel_start or 0), ffi.cast("jint", sel_end or sel_start or 0))
            local run_mid = env[0].GetMethodID(env, env[0].GetObjectClass(env, act),
                "runOnUiThread", "(Ljava/lang/Runnable;)V")
            env[0].CallVoidMethod(env, act, run_mid, shower)

            env[0].DeleteLocalRef(env, imm)
            env[0].DeleteLocalRef(env, ext_file)
            env[0].DeleteLocalRef(env, editor_text)
            env[0].DeleteLocalRef(env, shower)
        end)
    end

    local function sync(text, sel_start, sel_end)
        android.jni:context(jvm, function(jni)
            local env = jni.env
            local editor_text = jstr(env, text or "")
            local update = env[0].GetStaticMethodID(env, dex_class, "updateState",
                "(Ljava/lang/String;II)V")
            env[0].CallStaticVoidMethod(env, dex_class, update, editor_text,
                ffi.cast("jint", sel_start or 0), ffi.cast("jint", sel_end or sel_start or 0))
            env[0].DeleteLocalRef(env, editor_text)
        end)
    end

    local function hide()
        android.jni:context(jvm, function(jni)
            local env = jni.env
            local deactivate = env[0].GetStaticMethodID(env, dex_class, "hide", "()V")
            env[0].CallStaticVoidMethod(env, dex_class, deactivate)

            local win = jni:callObjectMethod(act, "getWindow", "()Landroid/view/Window;")
            local decor = jni:callObjectMethod(win, "getDecorView", "()Landroid/view/View;")
            local token = jni:callObjectMethod(decor, "getWindowToken", "()Landroid/os/IBinder;")
            local svc = jstr(env, "input_method")
            local imm = jni:callObjectMethod(act, "getSystemService",
                "(Ljava/lang/String;)Ljava/lang/Object;", svc)
            env[0].DeleteLocalRef(env, svc)
            jni:callBooleanMethod(imm, "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z", token, 0)
            env[0].DeleteLocalRef(env, win)
            env[0].DeleteLocalRef(env, decor)
            env[0].DeleteLocalRef(env, token)
            env[0].DeleteLocalRef(env, imm)
        end)
    end

    local function consume(path)
        local file = io.open(path, "r")
        if not file then return nil end
        local content = file:read("*a")
        file:close()
        pcall(os.remove, path)
        return content
    end

    local function readHeight()
        local file = io.open(paths.height, "r")
        if not file then return nil end
        local value = file:read("*a")
        file:close()
        return tonumber(value)
    end

    --- 原子认领 dex 侧写好的快照；旧版 BS 文件也算一个动作。
    ---@return string|nil
    local function takeInput()
        pcall(os.remove, paths.snapshot)
        local content
        if os.rename(paths.input, paths.snapshot) then
            content = consume(paths.snapshot)
        end
        local backspace = consume(paths.backspace)
        if backspace then
            content = "BS\n" .. (content or "")
        end
        if content == "" then return nil end
        return content
    end

    local function clear()
        pcall(os.remove, paths.input)
        pcall(os.remove, paths.snapshot)
        pcall(os.remove, paths.backspace)
        pcall(os.remove, paths.height)
    end

    return {
        paths = paths,
        show = show,
        hide = hide,
        sync = sync,
        read_height = readHeight,
        take_input = takeInput,
        clear = clear,
    }
end

--- 校验并安装 dex，加载 KOBoardShow，返回 JNI 引擎。
---@param android table|nil
---@param plugin_path string|nil
---@return table|nil engine
---@return string|nil err
function Engine.load(android, plugin_path)
    if type(android) ~= "table" then
        return nil, "android runtime unavailable"
    end
    if type(plugin_path) ~= "string" or plugin_path == "" then
        return nil, "plugin path unavailable"
    end

    local cache_dir = callFilePath(android, "getCacheDir", "()Ljava/io/File;")
    if not cache_dir then return nil, "cache dir unavailable" end

    local source = plugin_path .. "/features/system_ime/classes.dex"
    local dex_path, dex_err = Dex.stage(source, cache_dir .. "/moon_system_ime.dex", DEX_SHA256)
    if not dex_path then
        warn("system ime: dex not ready", dex_err)
        return nil, dex_err
    end

    local dex_class, class_err = loadClass(android, dex_path, cache_dir .. "/moon_system_ime_opt")
    if not dex_class then
        warn("system ime: dex load failed", class_err)
        return nil, class_err
    end

    local ext_dir = callFilePath(android, "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;")
    if not ext_dir then return nil, "external files dir unavailable" end

    local ok, engine = pcall(makeEngine, android, dex_class, ext_dir)
    if not ok or type(engine) ~= "table" then
        return nil, "jni bridge failed: " .. tostring(engine)
    end
    return engine
end

Engine.DEX_SHA256 = DEX_SHA256

return Engine
