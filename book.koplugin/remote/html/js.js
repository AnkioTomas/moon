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
/* 访问令牌：首次从地址栏 ?t= 取，之后存 sessionStorage（页面间跳转是普通链接） */
var TOKEN = (function () {
    var m = location.search.match(/[?&]t=([^&]*)/);
    var t = m ? decodeURIComponent(m[1]) : sessionStorage.getItem('rt') || '';
    if (t) sessionStorage.setItem('rt', t);
    return t;
})();
/* 给同站 URL 补上 token；页面链接与 API 请求都要 */
function withToken(u) {
    if (!TOKEN) return u;
    return u + (u.indexOf('?') < 0 ? '?' : '&') + 't=' + encodeURIComponent(TOKEN);
}
/* 顶部导航链接（/file.html 等）跳转后也要带 token */
function linkTokens() {
    var as = document.getElementsByTagName('a');
    for (var i = 0; i < as.length; i++) {
        var h = as[i].getAttribute('href');
        if (h && h.charAt(0) === '/' && h.indexOf('t=') < 0) as[i].setAttribute('href', withToken(h));
    }
}
document.addEventListener('DOMContentLoaded', linkTokens);
function jfetch(u, opt) {
    return fetch(withToken(u), opt).then(function (r) {
        return r.text().then(function (t) {
            var d;
            try { d = JSON.parse(t); } catch (e) { throw 'HTTP ' + r.status; }
            if (!r.ok) throw (d && d.error) || ('HTTP ' + r.status);
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
