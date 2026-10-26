// ── 多语言：跟随 KOReader 语言。源文案即简体中文；/api/i18n 下发 {lang, html, strings}，
// 每次页面加载取一次。t() 查表（支持 %1 %2 占位），DOM 文本与 title/placeholder/aria-label
// 由 MutationObserver 自动替换，动态生成的对话框/提示/菜单无需逐处改调用。
var I18N = (function () {
    var data = { lang: 'zh_CN', html: 'zh-CN', strings: {} };
    try {
        var x = new XMLHttpRequest();
        x.open('GET', '/api/i18n', false);
        x.send();
        if (x.status === 200) {
            var d = JSON.parse(x.responseText);
            if (d && typeof d.strings === 'object') data = d;
        }
    } catch (e) { /* 取不到就用中文 */ }
    try { localStorage.setItem('moon-lang', data.lang || 'zh_CN'); } catch (e) {}
    var dict = data.strings || {};
    var tpls = [];
    Object.keys(dict).forEach(function (k) {
        if (k.indexOf('%1') < 0) return;
        var lit = k.replace(/%\d/g, '').length;
        var re = '^' + k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%(\d)/g, '([\\s\\S]+?)') + '$';
        tpls.push({ re: new RegExp(re), order: (k.match(/%\d/g) || []).map(function (m) { return +m.charAt(1); }), out: dict[k], lit: lit });
    });
    tpls.sort(function (a, b) { return b.lit - a.lit; });
    function fill(s, args) {
        return s.replace(/%(\d)/g, function (m, n) { var v = args[n - 1]; return v == null ? m : v; });
    }
    // 只翻译模板本身，捕获段可能是用户文件名或路径，必须原样保留。
    function tr(s) {
        if (!s) return s;
        if (Object.prototype.hasOwnProperty.call(dict, s)) return dict[s];
        for (var i = 0; i < tpls.length; i++) {
            var m = tpls[i].re.exec(s);
            if (!m) continue;
            var args = [];
            tpls[i].order.forEach(function (n, j) { args[n - 1] = m[j + 1]; });
            return fill(tpls[i].out, args);
        }
        return s;
    }
    function t(key) {
        var args = Array.prototype.slice.call(arguments, 1);
        var s = Object.prototype.hasOwnProperty.call(dict, key) ? dict[key] : key;
        return args.length ? fill(s, args) : s;
    }
    var active = Object.keys(dict).length > 0;
    var ATTRS = ['title', 'placeholder', 'aria-label', 'alt'];
    // 文件名、路径等用户数据打 translate="no"，不参与替换
    function skip(e) { return !e || (e.closest && e.closest('[translate="no"]')); }
    function trText(node) {
        if (skip(node.parentNode)) return;
        var tag = node.parentNode.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TEXTAREA') return;
        var v = node.nodeValue;
        if (!v || !/[\u3000-\u9fff\uff00-\uffef]/.test(v)) return;
        var m = /^(\s*)([\s\S]*?)(\s*)$/.exec(v);
        var out = tr(m[2]);
        if (out !== m[2]) node.nodeValue = m[1] + out + m[3];
    }
    function trEl(e) {
        if (e.nodeType !== 1 || skip(e)) return;
        var key = e.getAttribute('data-i18n');
        if (key && e.textContent !== t(key)) e.textContent = t(key);
        ATTRS.forEach(function (a) {
            var v = e.getAttribute(a);
            if (v && /[\u3000-\u9fff\uff00-\uffef]/.test(v)) {
                var out = tr(v.trim());
                if (out !== v.trim()) e.setAttribute(a, out);
            }
        });
    }
    function walk(root) {
        if (root.nodeType === 3) return trText(root);
        if (root.nodeType !== 1 || root.tagName === 'SCRIPT' || root.tagName === 'STYLE') return;
        trEl(root);
        var w = document.createTreeWalker(root, 5, null);
        var n;
        while ((n = w.nextNode())) {
            if (n.nodeType === 3) trText(n); else trEl(n);
        }
    }
    function start() {
        document.documentElement.lang = data.html || 'zh-CN';
        if (active) {
            walk(document.documentElement);
            new MutationObserver(function (list) {
                list.forEach(function (r) {
                    if (r.type === 'characterData') trText(r.target);
                    else if (r.type === 'attributes') trEl(r.target);
                    else r.addedNodes.forEach(walk);
                });
            }).observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ATTRS.concat('data-i18n') });
        }
        document.documentElement.classList.remove('i18n-wait');
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
    return { lang: data.lang, t: t, tr: function (s) { return tr(s); } };
})();
function t() { return I18N.t.apply(null, arguments); }

/* 远程管理共享 JS：各页面共用（经 /js.js 路由加载） */
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
    // 每行单独文本节点，才能逐句翻译
    log.appendChild(document.createTextNode(I18N.tr(String(s)) + '\n'));
}
function setState(node, text, kind) {
    if (!node) return;
    node.textContent = text || '';
    node.className = 'state' + (kind ? ' ' + kind : '');
}
function jfetch(u, opt) {
    return fetch(u, opt).then(function (r) {
        return r.text().then(function (text) {
            var d;
            try { d = JSON.parse(text); } catch (e) { throw 'HTTP ' + r.status; }
            if (!r.ok) {
                var err = new Error(t((d && d.error) || ('HTTP ' + r.status)));
                err.status = r.status;
                throw err;
            }
            return d;
        });
    });
}
/* 定时轮询：fn 返回不会 reject 的 Promise，结束后才排下一轮（请求不叠）。
   页面隐藏时不排下一轮：后台标签页一直轮询会让设备的空闲自动关闭永不触发；回到前台立刻补一次。 */
function pollWhileVisible(fn, ms) {
    var timer = null;
    var running = false;
    function tick() {
        timer = null;
        if (document.hidden) return;
        running = true;
        fn().then(function () {
            running = false;
            if (!document.hidden) timer = setTimeout(tick, ms);
        });
    }
    document.addEventListener('visibilitychange', function () {
        if (!document.hidden && !timer && !running) tick();
    });
    tick();
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

/* 主题：跟随系统 → 浅色 → 深色 循环；存 localStorage，<head> 里的小脚本在首帧前套用，避免闪白。 */
(function () {
    var btn = el('theme-toggle');
    if (!btn) return;
    var order = ['auto', 'light', 'dark'];
    var label = { auto: '跟随系统', light: '浅色', dark: '深色' };
    function current() {
        var t = document.documentElement.getAttribute('data-theme');
        return t === 'light' || t === 'dark' ? t : 'auto';
    }
    function show(theme) {
        btn.title = t('主题：%1', t(label[theme]));
        btn.setAttribute('aria-label', t('切换主题（当前：%1）', t(label[theme])));
    }
    show(current());
    btn.onclick = function () {
        var next = order[(order.indexOf(current()) + 1) % order.length];
        if (next === 'auto') document.documentElement.removeAttribute('data-theme');
        else document.documentElement.setAttribute('data-theme', next);
        try {
            if (next === 'auto') localStorage.removeItem('moon-theme');
            else localStorage.setItem('moon-theme', next);
        } catch (e) {}
        show(next);
    };
})();

/* 收拢顶栏：常驻首页、当前页名和主题按钮，其余入口放进下拉菜单。 */
window.collapseRemoteNav = function () {
    var nav = document.querySelector('.appbar-nav');
    if (!nav || nav.dataset.compact === 'true') return;

    var links = Array.prototype.slice.call(nav.querySelectorAll(':scope > a'));
    var home = links.find(function (a) { return new URL(a.href, location.origin).pathname === '/'; });
    var current = links.find(function (a) { return a.getAttribute('aria-current') === 'page'; })
        || links.find(function (a) { return new URL(a.href, location.origin).pathname === location.pathname; });
    var currentName = current && current.querySelector('span')
        ? current.querySelector('span').textContent.trim()
        : document.title.replace(/\s*-\s*远程管理$/, '');
    var more = document.createElement('details');
    more.className = 'appbar-menu';

    var summary = document.createElement('summary');
    summary.setAttribute('aria-label', t('更多页面'));
    var icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    icon.setAttribute('viewBox', '0 0 24 24');
    icon.setAttribute('width', '20');
    icon.setAttribute('height', '20');
    icon.setAttribute('fill', 'currentColor');
    icon.setAttribute('aria-hidden', 'true');
    path.setAttribute('d', 'M12 8a2 2 0 1 0 0-4 2 2 0 0 0 0 4zm0 2a2 2 0 1 0 0 4 2 2 0 0 0 0-4zm0 6a2 2 0 1 0 0 4 2 2 0 0 0 0-4z');
    icon.appendChild(path);
    summary.appendChild(icon);
    more.appendChild(summary);

    var menu = document.createElement('div');
    menu.className = 'appbar-menu-links';
    links.forEach(function (a) {
        if (a !== home && a !== current) menu.appendChild(a);
    });
    more.appendChild(menu);

    nav.replaceChildren();
    if (home) nav.appendChild(home);
    if (currentName && current !== home) {
        var title = document.createElement('span');
        title.className = 'appbar-current';
        title.setAttribute('aria-current', 'page');
        title.textContent = currentName;
        nav.appendChild(title);
    }
    if (menu.childElementCount) nav.appendChild(more);
    nav.dataset.compact = 'true';
    nav.classList.add('appbar-nav-ready');

    document.addEventListener('click', function (event) {
        if (!more.contains(event.target)) more.open = false;
    });
    document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') more.open = false;
    });
};

/* 扩展页面：功能模块经 web.routes 登记的页面（/api/pages → [{href, title, desc, icon, tile}]），
   补进顶栏导航与首页入口列表（插在「配置」前）。远程管理本身不认识任何具体功能。 */
(function () {
    function svg(path, size) {
        var ns = 'http://www.w3.org/2000/svg', s = document.createElementNS(ns, 'svg'), p = document.createElementNS(ns, 'path');
        s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('width', size); s.setAttribute('height', size);
        s.setAttribute('fill', 'currentColor'); s.setAttribute('aria-hidden', 'true');
        p.setAttribute('d', path || ''); s.appendChild(p);
        return s;
    }
    function span(cls, text) { var e = document.createElement('span'); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
    function insert(parent, node) {
        var ref = parent.querySelector('a[href="/settings.html"]');
        parent.insertBefore(node, ref);
    }
    jfetch('/api/pages').then(function (pages) {
        (pages || []).forEach(function (pg) {
            var nav = document.querySelector('.appbar-nav');
            if (nav && !nav.querySelector('a[href="' + pg.href + '"]')) {
                var a = document.createElement('a');
                a.href = pg.href;
                if (location.pathname === pg.href) a.setAttribute('aria-current', 'page');
                a.appendChild(svg(pg.icon, 18)); a.appendChild(span(null, t(pg.title)));
                insert(nav, a);
            }
            var list = document.querySelector('.setting-row[href="/settings.html"]');
            if (list && pg.desc && !list.parentNode.querySelector('.setting-row[href="' + pg.href + '"]')) {
                var row = document.createElement('a');
                row.href = pg.href; row.className = 'setting-row';
                var ic = span('row-icon ' + (pg.tile || 'tile-slate')); ic.setAttribute('aria-hidden', 'true'); ic.appendChild(svg(pg.icon, 24));
                var tx = span('row-text'); tx.appendChild(span('row-title', t(pg.title_long || pg.title))); tx.appendChild(span('row-sub', t(pg.desc)));
                var ch = span('row-chevron'); ch.setAttribute('aria-hidden', 'true'); ch.appendChild(svg('M8.6 16.6 13.2 12 8.6 7.4 10 6l6 6-6 6z', 18));
                row.appendChild(ic); row.appendChild(tx); row.appendChild(ch);
                insert(list.parentNode, row);
            }
        });
    }).catch(function () {}).finally(function () {
        window.collapseRemoteNav();
    });
})();
