/* 共享剪贴板：点击时整段传输；轮询只在本地未编辑时跟随设备。 */
var text = el('cbtext');
var push = el('cbpush');
var pull = el('cbpull');
var clear = el('cbclear');
var copy = el('cbcopy');
var state = el('cbstate');
var pulled = '';
var busy = false;

function setBusy(on) {
    busy = on;
    push.disabled = on;
    pull.disabled = on;
    clear.disabled = on;
    copy.disabled = on;
}

function flash(message) {
    setState(state, message, 'ok');
    pulled = text.value;
}

function poll() {
    jfetch('/api/clipboard').then(function (data) {
        var remote = data.text || '';
        if (text.value === pulled && remote !== text.value) text.value = remote;
        pulled = remote;
    }).catch(function () {
        /* 主动操作会显示错误；后台轮询失败不打断编辑。 */
    }).then(function () {
        setTimeout(poll, 2000);
    });
}

push.onclick = function () {
    if (busy) return;
    setBusy(true);
    jfetch('/api/clipboard', { method: 'POST', body: text.value }).then(function () {
        flash('已写入设备 ✓');
    }).catch(function (err) {
        setState(state, '发送失败: ' + err, 'err');
    }).then(function () {
        setBusy(false);
    });
};

pull.onclick = function () {
    if (busy) return;
    setBusy(true);
    jfetch('/api/clipboard').then(function (data) {
        text.value = data.text || '';
        flash('已从设备拉取 ✓');
    }).catch(function (err) {
        setState(state, '拉取失败: ' + err, 'err');
    }).then(function () {
        setBusy(false);
    });
};

clear.onclick = function () {
    if (busy) return;
    setBusy(true);
    text.value = '';
    jfetch('/api/clipboard', { method: 'POST', body: '' }).then(function () {
        flash('已清空设备剪贴板 ✓');
    }).catch(function (err) {
        setState(state, '清空失败: ' + err, 'err');
    }).then(function () {
        setBusy(false);
    });
};

copy.onclick = function () {
    if (busy) return;
    if (!navigator.clipboard || !navigator.clipboard.writeText) {
        setState(state, '当前浏览器不支持剪贴板 API（需 HTTPS 或 localhost）', 'err');
        return;
    }
    setBusy(true);
    navigator.clipboard.writeText(text.value).then(function () {
        flash('已复制到本机剪贴板 ✓');
    }).catch(function () {
        setState(state, '复制失败：浏览器拒绝了剪贴板访问', 'err');
    }).then(function () {
        setBusy(false);
    });
};

poll();
