/* 连接配置页逻辑（依赖 /js.js） */
var feeds = [];

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

function renderFeeds() {
    var list = el('rss-list');
    list.innerHTML = '';
    if (!feeds.length) {
        var li = document.createElement('li');
        li.className = 'rss-empty';
        li.textContent = '暂无订阅';
        list.appendChild(li);
        return;
    }
    feeds.forEach(function (feed, index) {
        var li = document.createElement('li');
        li.className = 'rss-item';
        var title = document.createElement('span');
        title.className = 'rss-title';
        title.textContent = (feed.title && feed.title !== '') ? feed.title : feed.url;
        var url = document.createElement('span');
        url.className = 'rss-url';
        url.textContent = feed.url;
        var del = document.createElement('button');
        del.type = 'button';
        del.className = 'danger';
        del.textContent = '删除';
        del.addEventListener('click', function () {
            feeds.splice(index, 1);
            renderFeeds();
        });
        li.appendChild(title);
        li.appendChild(url);
        li.appendChild(del);
        list.appendChild(li);
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
            webdav_url: data.webdav.url,
            webdav_username: data.webdav.username,
            webdav_password: data.webdav.password,
            zlib_email: data.zlib.email,
            zlib_password: data.zlib.password,
            zlib_base_url: data.zlib.base_url,
        });
        feeds = (data.rss && data.rss.feeds) ? data.rss.feeds.slice() : [];
        renderFeeds();
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
bindForm('form-webdav', 'webdav', 'state-webdav');
bindForm('form-zlib', 'zlib', 'state-zlib');

el('form-rss-add').addEventListener('submit', function (e) {
    e.preventDefault();
    var url = el('rss_url').value.trim();
    if (!url) return;
    var title = el('rss_title').value.trim();
    for (var i = 0; i < feeds.length; i++) {
        if (feeds[i].url === url) {
            setFormState('state-rss', '该订阅已存在', 'err');
            return;
        }
    }
    feeds.push({ url: url, title: title });
    el('rss_url').value = '';
    el('rss_title').value = '';
    renderFeeds();
    setFormState('state-rss', '已加入列表，记得点「保存订阅列表」', 'ok');
});

el('rss-save').addEventListener('click', function () {
    setFormState('state-rss', '保存中…', '');
    saveGroup('rss', { feeds: feeds }).then(function () {
        setFormState('state-rss', '订阅列表已保存', 'ok');
        return loadSettings();
    }).catch(function (err) {
        setFormState('state-rss', String(err), 'err');
    });
});

el('rss-opml').addEventListener('change', function (e) {
    var file = e.target.files && e.target.files[0];
    e.target.value = '';
    if (!file) return;
    setFormState('state-rss', '导入中…', '');
    var reader = new FileReader();
    reader.onload = function () {
        var text = reader.result || '';
        fetch('/api/settings/rss/opml', {
            method: 'POST',
            headers: { 'Content-Type': 'text/xml; charset=utf-8' },
            body: text,
        }).then(function (r) {
            return r.text().then(function (t) {
                var d;
                try { d = JSON.parse(t); } catch (err) { throw 'HTTP ' + r.status; }
                if (!r.ok) throw (d && d.error) || ('HTTP ' + r.status);
                return d;
            });
        }).then(function (d) {
            setFormState('state-rss', '已导入 ' + (d.added || 0) + ' 个订阅', 'ok');
            return loadSettings();
        }).catch(function (err) {
            setFormState('state-rss', String(err), 'err');
        });
    };
    reader.onerror = function () {
        setFormState('state-rss', '无法读取文件', 'err');
    };
    reader.readAsText(file);
});

loadSettings();
