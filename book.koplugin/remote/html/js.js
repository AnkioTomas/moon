/* 远程管理共享 JS：文件管理 / 远程输入页面共用（经 /js.js 路由加载） */
function fmt(n) {
    if (n == null) return '';
    if (n > 1073741824) return (n / 1073741824).toFixed(1) + ' G';
    if (n > 1048576) return (n / 1048576).toFixed(1) + ' M';
    if (n > 1024) return (n / 1024).toFixed(0) + ' K';
    return n + ' B';
}
function fmtT(t) {
    if (!t) return '';
    var d = new Date(t * 1000);
    function p(x) { return (x < 10 ? '0' : '') + x; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
        ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}
function el(id) { return document.getElementById(id); }
function say(s) {
    var log = el('log');
    if (!log) return;
    log.textContent += s + '\n';
}
function setState(node, text, kind) {
    if (!node) return;
    node.textContent = text || '';
    node.className = 'state' + (kind ? ' ' + kind : '');
}
function jfetch(u, opt) {
    return fetch(u, opt).then(function (r) {
        return r.text().then(function (t) {
            var d;
            try { d = JSON.parse(t); } catch (e) { throw 'HTTP ' + r.status; }
            if (!r.ok) {
                var err = new Error((d && d.error) || ('HTTP ' + r.status));
                err.status = r.status;
                throw err;
            }
            return d;
        });
    });
}
/* 页面配置（root/home/shortcuts 由 /api/config 提供，免模板注入） */
function loadConfig() {
    return jfetch('/api/config');
}

/* 自绘弹窗：prompt / confirm 的替代（原生弹窗在部分浏览器样式突兀） */
var _dlgFocus = null;
var _dlgKeyHandler = null;
function dialog(o) {
    var ov = el('ov');
    var di = el('di');
    var dk = el('dk');
    var dc = el('dc');
    var dm = el('dm');
    var dilabel = el('dilabel');
    var oldChoices = document.querySelectorAll('.dialog-choice');
    for (var i = 0; i < oldChoices.length; i++) oldChoices[i].remove();
    _dlgFocus = document.activeElement;

    el('dt').textContent = o.title || '';
    dm.textContent = o.msg || '';
    dm.hidden = !o.msg;

    if (o.input == null) {
        di.hidden = true;
        di.removeAttribute('required');
        if (dilabel) dilabel.textContent = '输入';
    } else {
        di.hidden = false;
        di.value = o.input || '';
        if (dilabel) dilabel.textContent = o.title || '输入';
    }

    dk.hidden = !!o.choices;
    dk.textContent = o.ok || '确定';
    dk.className = o.danger ? 'danger' : 'primary';
    ov.hidden = false;
    ov.className = 'overlay on';

    function close(v) {
        ov.className = 'overlay';
        ov.hidden = true;
        if (_dlgKeyHandler) {
            document.removeEventListener('keydown', _dlgKeyHandler);
            _dlgKeyHandler = null;
        }
        dc.onclick = null;
        dk.onclick = null;
        di.onkeydown = null;
        ov.onclick = null;
        if (_dlgFocus && _dlgFocus.focus) {
            try { _dlgFocus.focus(); } catch (e) {}
        }
        _dlgFocus = null;
        return v;
    }

    return new Promise(function (res) {
        function cancel() { res(close(null)); }
        function ok() { res(close(o.input == null ? true : di.value)); }

        dc.onclick = cancel;
        dk.onclick = ok;
        if (o.choices) {
            o.choices.forEach(function (choice) {
                var b = document.createElement('button');
                b.type = 'button';
                b.className = 'dialog-choice' + (choice.kind ? ' ' + choice.kind : '');
                b.textContent = choice.text;
                b.onclick = function () { res(close(choice.value)); };
                dk.parentNode.appendChild(b);
            });
        }
        di.onkeydown = function (e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                ok();
            }
        };
        ov.onclick = function (e) {
            if (e.target === ov) cancel();
        };
        _dlgKeyHandler = function (e) {
            if (e.key === 'Escape') {
                e.preventDefault();
                cancel();
            }
        };
        document.addEventListener('keydown', _dlgKeyHandler);

        if (o.input != null) {
            di.focus();
            di.select();
        } else {
            dk.focus();
        }
    });
}
