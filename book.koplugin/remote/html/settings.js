/* 连接配置页逻辑（依赖 /js.js） */
function setFormState(id, text, kind) {
    setState(el(id), text, kind);
}

function fillFields(map) {
    Object.keys(map).forEach(function (id) {
        var node = el(id);
        if (node && map[id] != null) {
            node.value = map[id];
        }
    });
}

function readGroup(form) {
    var data = {};
    var nodes = form.querySelectorAll('input[name]');
    for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        data[n.name] = n.value;
    }
    return data;
}

function saveGroup(groupName, payload) {
    var body = {};
    body[groupName] = payload;
    return jfetch('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
        body: JSON.stringify(body),
    });
}

function loadSettings() {
    return jfetch('/api/settings').then(function (data) {
        fillFields({
            ai_endpoint: data.ai.ai_endpoint,
            ai_api_key: data.ai.ai_api_key,
            ai_model: data.ai.ai_model,
            moon_base_url: data.moon.base_url,
            moon_token: data.moon.token,
            zlib_email: data.zlib.email,
            zlib_password: data.zlib.password,
            zlib_base_url: data.zlib.base_url,
        });
        setState(el('loadstate'), '已加载设备配置', 'ok');
    }).catch(function (err) {
        setState(el('loadstate'), String(err), 'err');
    });
}

function bindForm(formId, groupName, stateId) {
    var form = el(formId);
    form.addEventListener('submit', function (e) {
        e.preventDefault();
        setFormState(stateId, '保存中…', '');
        saveGroup(groupName, readGroup(form)).then(function () {
            setFormState(stateId, '已保存', 'ok');
            return loadSettings();
        }).catch(function (err) {
            setFormState(stateId, String(err), 'err');
        });
    });
}

bindForm('form-ai', 'ai', 'state-ai');
bindForm('form-moon', 'moon', 'state-moon');
bindForm('form-zlib', 'zlib', 'state-zlib');

loadSettings();
