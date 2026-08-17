/* 远程输入 / 共享剪贴板页面逻辑（依赖 /js.js 共享函数）
   - 共享剪贴板：GET/POST /api/clipboard，设备最后复制的文本（阅读划线复制、
     链接复制等都在服务端镜像），随时可拉取/覆盖，与输入框激活无关；
     写入设备时若正好有激活输入框，会同步 setText 进去。
   - 远程输入：GET/POST /api/input，激活输入框才能用，addChars 光标处追加。
   两边都是点击时整段传输；剪贴板轮询跟随设备端新复制（本地编辑中不打断）。 */
var cbtext = el('cbtext');
var cbpush = el('cbpush');
var cbpull = el('cbpull');
var cbclear = el('cbclear');
var cbcopy = el('cbcopy');
var cbstate = el('cbstate');
var ritext = el('ritext');
var risend = el('risend');
var ristate = el('ristate');
var pulled = ''; /* 上次从设备读到的剪贴板文本；本地编辑 ≠ 设备变更，靠它区分 */
var inputActive = false;
var sending = false;
var clipboardBusy = false;

function flash(s, kind) {
    setState(cbstate, s, kind || 'ok');
    pulled = cbtext.value; /* 设备剪贴板已被本次操作改写，别让下一轮轮询闪回 */
}

function setClipboardBusy(on) {
    clipboardBusy = on;
    cbpush.disabled = on;
    cbpull.disabled = on;
    cbclear.disabled = on;
    cbcopy.disabled = on;
}

function applyInputState(active) {
    inputActive = !!active;
    if (!sending) {
        ritext.disabled = !inputActive;
        risend.disabled = !inputActive;
    }
    if (inputActive) {
        setState(ristate, '设备输入框已激活，可以发送', 'ok');
    } else {
        setState(ristate, '设备上暂无激活的输入框', '');
    }
}

/* 共享剪贴板 */
function pollClipboard() {
    jfetch('/api/clipboard').then(function (d) {
        var text = d.text || '';
        if (cbtext.value === pulled && text !== cbtext.value) {
            cbtext.value = text; /* 本地未改动才跟随设备新复制，不打断正在编辑的内容 */
        }
        pulled = text;
    }).catch(function () {
        /* 轮询失败静默；用户主动操作会显示错误 */
    }).then(function () {
        setTimeout(pollClipboard, 2000);
    });
}

cbpush.onclick = function () {
    if (clipboardBusy) return;
    setClipboardBusy(true);
    jfetch('/api/clipboard', { method: 'POST', body: cbtext.value }).then(function () {
        flash('已写入设备 ✓', 'ok');
    }).catch(function (e) {
        setState(cbstate, '发送失败: ' + e, 'err');
    }).then(function () {
        setClipboardBusy(false);
    });
};

cbpull.onclick = function () {
    if (clipboardBusy) return;
    setClipboardBusy(true);
    jfetch('/api/clipboard').then(function (d) {
        cbtext.value = d.text || '';
        flash('已从设备拉取 ✓', 'ok');
    }).catch(function (e) {
        setState(cbstate, '拉取失败: ' + e, 'err');
    }).then(function () {
        setClipboardBusy(false);
    });
};

cbclear.onclick = function () {
    if (clipboardBusy) return;
    setClipboardBusy(true);
    cbtext.value = '';
    jfetch('/api/clipboard', { method: 'POST', body: '' }).then(function () {
        flash('已清空设备剪贴板 ✓', 'ok');
    }).catch(function (e) {
        setState(cbstate, '清空失败: ' + e, 'err');
    }).then(function () {
        setClipboardBusy(false);
    });
};

cbcopy.onclick = function () {
    if (clipboardBusy) return;
    if (!navigator.clipboard || !navigator.clipboard.writeText) {
        setState(cbstate, '当前浏览器不支持剪贴板 API（需 HTTPS 或 localhost）', 'err');
        return;
    }
    setClipboardBusy(true);
    navigator.clipboard.writeText(cbtext.value).then(function () {
        flash('已复制到本机剪贴板 ✓', 'ok');
    }).catch(function () {
        setState(cbstate, '复制失败：浏览器拒绝了剪贴板访问', 'err');
    }).then(function () {
        setClipboardBusy(false);
    });
};

/* 远程输入（光标处追加，语义与旧版一致） */
function pollInput() {
    jfetch('/api/input').then(function (d) {
        applyInputState(d.active);
    }).catch(function () {
        if (!sending) {
            setState(ristate, '状态检测失败，稍后重试', 'err');
            ritext.disabled = true;
            risend.disabled = true;
        }
    }).then(function () {
        setTimeout(pollInput, 3000);
    });
}

risend.onclick = function () {
    var text = ritext.value;
    if (!text || sending || !inputActive) return;
    sending = true;
    risend.disabled = true;
    jfetch('/api/input', { method: 'POST', body: text }).then(function () {
        ritext.value = '';
        setState(ristate, '已发送 ✓', 'ok');
    }).catch(function (e) {
        setState(ristate, '发送失败: ' + e, 'err');
    }).then(function () {
        sending = false;
        /* 恢复按钮状态依据当前激活状态，避免轮询与提交互相覆盖 */
        ritext.disabled = !inputActive;
        risend.disabled = !inputActive;
    });
};

pollClipboard();
pollInput();
