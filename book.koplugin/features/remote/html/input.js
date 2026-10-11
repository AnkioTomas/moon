/* 远程输入：GET/POST /api/input，激活输入框后在光标处追加文本。 */
var ritext = el('ritext');
var risend = el('risend');
var ristate = el('ristate');
var inputActive = false;
var sending = false;

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

pollInput();
