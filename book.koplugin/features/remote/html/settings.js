/* 连接配置页逻辑（依赖 /js.js） */
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

/* 按设备下发的字段声明建表单（只建一次，之后只回填值）。
   内置分组按 id 提交；第三方源（external）提交到 external[源 id]。 */
function renderForms(list, external) {
    var grid = document.querySelector('.settings-grid');
    var prefix = external ? 'form-ext-' : 'form-';
    list.forEach(function (src) {
        var formId = prefix + src.id;
        var form = el(formId);
        if (!form) {
            form = document.createElement('form');
            form.id = formId;
            form.className = 'panel cfg-form';
            form.autocomplete = 'off';
            var title = document.createElement('h2');
            title.textContent = src.name;
            form.appendChild(title);
            src.fields.forEach(function (f) {
                var field = document.createElement('div');
                field.className = 'field';
                var label = document.createElement('label');
                var input = document.createElement('input');
                input.id = formId + '-' + f.key;
                input.name = f.key;
                input.type = f.type;
                input.placeholder = f.placeholder;
                label.htmlFor = input.id;
                label.textContent = f.label;
                field.appendChild(label);
                field.appendChild(input);
                form.appendChild(field);
            });
            var btns = document.createElement('div');
            btns.className = 'btns';
            var button = document.createElement('button');
            button.type = 'submit';
            button.className = 'primary';
            button.textContent = '保存' + src.name + '配置';
            btns.appendChild(button);
            form.appendChild(btns);
            var state = document.createElement('div');
            state.className = 'state';
            state.setAttribute('role', 'status');
            state.setAttribute('aria-live', 'polite');
            form.appendChild(state);
            grid.appendChild(form);
            form.addEventListener('submit', function (e) {
                e.preventDefault();
                var group = src.id;
                var payload = readGroup(form);
                if (external) {
                    group = 'external';
                    payload = {};
                    payload[src.id] = readGroup(form);
                }
                setState(state, '保存中…', '');
                saveGroup(group, payload).then(function () {
                    setState(state, '已保存', 'ok');
                    return loadSettings();
                }).catch(function (err) {
                    setState(state, String(err), 'err');
                });
            });
        }
        src.fields.forEach(function (f) {
            el(formId + '-' + f.key).value = f.value;
        });
    });
}

/* 空列表经 Lua JSON 编码成 {}，不是数组。 */
function formList(v) {
    return Array.isArray(v) ? v : [];
}

function loadSettings() {
    return jfetch('/api/settings').then(function (data) {
        renderForms(formList(data.builtin), false);
        renderForms(formList(data.external), true);
        setState(el('loadstate'), '已加载设备配置', 'ok');
    }).catch(function (err) {
        setState(el('loadstate'), String(err), 'err');
    });
}

loadSettings();

/* 配置备份恢复：上传 /api/backup 下载的文件，设备校验后写入并重启。 */
(function () {
    var input = el('bkfile');
    var pick = el('bkpick');
    var state = el('bkstate');
    var dl = el('bkdl');
    dl.onclick = function () {
        dl.disabled = true;
        setState(state, '正在生成备份，请稍候…', '');
        fetch('/api/backup').then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            var name = /filename\*=UTF-8''([^;]+)/.exec(res.headers.get('Content-Disposition') || '');
            return res.blob().then(function (blob) {
                var a = document.createElement('a');
                a.href = URL.createObjectURL(blob);
                a.download = name ? decodeURIComponent(name[1]) : 'moon-backup.lua';
                a.click();
                URL.revokeObjectURL(a.href);
            });
        }).then(function () {
            setState(state, '备份已下载 ✓', 'ok');
        }).catch(function (err) {
            setState(state, t('下载失败：%1', err.message || String(err)), 'err');
        }).then(function () { dl.disabled = false; });
    };
    pick.onclick = function () { input.click(); };
    input.onchange = function () {
        var file = input.files[0];
        input.value = '';
        if (!file || !window.confirm(t('恢复会覆盖设备上的月读配置，并重启 KOReader，继续吗？'))) return;
        pick.disabled = true;
        setState(state, '正在恢复…', '');
        jfetch('/api/backup', { method: 'POST', body: file }).then(function () {
            setState(state, '已恢复 ✓ KOReader 正在重启，稍后可重新连接。', 'ok');
        }).catch(function (err) {
            setState(state, t('恢复失败：%1', err.status === 400 ? t('不是有效的月读配置备份') : (err.message || String(err))), 'err');
            pick.disabled = false;
        });
    };
})();
