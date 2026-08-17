/* 文件管理页面逻辑（依赖 /js.js 共享函数与 /api/config） */
loadConfig().then(function (config) {
    var cur = config.home;
    var hist = [];
    var seq = 0;
    var busy = false;
    var backBtn = el('back');
    var upBtn = el('up');
    var mkBtn = el('mk');
    var fileInput = el('file');

    function setBusy(on) {
        busy = on;
        upBtn.disabled = on;
        mkBtn.disabled = on;
        fileInput.disabled = on;
        backBtn.disabled = on || hist.length === 0;
        var quick = el('quick');
        var buttons = quick.getElementsByTagName('button');
        for (var i = 0; i < buttons.length; i++) {
            buttons[i].disabled = on;
        }
    }

    function join(dir, name) {
        return (dir === '/' ? '' : dir) + '/' + name;
    }

    function addCell(tr, text, className, label) {
        var td = document.createElement('td');
        if (className) td.className = className;
        if (label) td.setAttribute('data-label', label);
        td.textContent = text;
        tr.appendChild(td);
        return td;
    }

    function render(d) {
        var tb = el('list');
        tb.innerHTML = '';

        if (d.parent) {
            var tr0 = document.createElement('tr');
            tr0.className = 'd';
            var td0 = document.createElement('td');
            td0.className = 'n';
            var a0 = document.createElement('a');
            a0.href = '#';
            a0.textContent = '../';
            a0.onclick = function () {
                if (!busy) load(d.parent);
                return false;
            };
            td0.appendChild(a0);
            tr0.appendChild(td0);
            addCell(tr0, '', 'r', '大小');
            addCell(tr0, '', 'r', '修改时间');
            addCell(tr0, '', 'ops r', '操作');
            tb.appendChild(tr0);
        }

        d.entries.forEach(function (e) {
            var full = join(cur, e.name);
            var tr = document.createElement('tr');
            if (e.dir) tr.className = 'd';

            var td = document.createElement('td');
            td.className = 'n';
            var a = document.createElement('a');
            a.textContent = e.name + (e.dir ? '/' : '');
            if (e.dir) {
                a.href = '#';
                a.onclick = function () {
                    if (!busy) load(full);
                    return false;
                };
            } else {
                a.href = '/download?path=' + encodeURIComponent(full);
            }
            td.appendChild(a);
            tr.appendChild(td);

            addCell(tr, e.dir ? '' : fmt(e.size), 'r', '大小');
            addCell(tr, fmtT(e.mtime), 'r', '修改时间');

            var op = document.createElement('td');
            op.className = 'ops r';
            op.setAttribute('data-label', '操作');
            if (!e.protected) {
                var rn = document.createElement('a');
                rn.className = 'act rn';
                rn.href = '#';
                rn.textContent = '重命名';
                rn.onclick = function () {
                    if (busy) return false;
                    dialog({
                        title: '重命名 / 移动',
                        msg: full,
                        input: full,
                        ok: '保存'
                    }).then(function (to) {
                        if (!to || to === full) return;
                        jfetch(
                            '/api/rename?path=' + encodeURIComponent(full) +
                            '&to=' + encodeURIComponent(to),
                            { method: 'POST' }
                        ).then(function () {
                            load(cur, true);
                        }).catch(function (err) {
                            say('重命名失败: ' + err);
                        });
                    });
                    return false;
                };

                var del = document.createElement('a');
                del.className = 'act';
                del.href = '#';
                del.textContent = '删除';
                del.onclick = function () {
                    if (busy) return false;
                    dialog({
                        title: '删除',
                        msg: '删除 ' + full + ' ？目录将递归删除，不可恢复。',
                        ok: '删除',
                        danger: true
                    }).then(function (yes) {
                        if (!yes) return;
                        jfetch('/api/delete?path=' + encodeURIComponent(full), {
                            method: 'POST'
                        }).then(function () {
                            load(cur, true);
                        }).catch(function (err) {
                            say('删除失败: ' + err);
                        });
                    });
                    return false;
                };
                op.appendChild(rn);
                op.appendChild(del);
            }
            tr.appendChild(op);
            tb.appendChild(tr);
        });

        if (!d.entries.length && !d.parent) {
            tb.innerHTML = '<tr><td class="empty" colspan="4">空目录</td></tr>';
        }
    }

    function load(p, nohist) {
        if (busy) return;
        var my = ++seq;
        jfetch('/api/list?path=' + encodeURIComponent(p)).then(function (d) {
            if (my !== seq) return; /* 丢弃过期响应 */
            if (!nohist && d.path !== cur) hist.push(cur);
            cur = d.path;
            backBtn.disabled = hist.length === 0;
            el('path').textContent = cur;
            /* 书籍根目录的目录约定只在首页提示，进入其它目录不打扰 */
            el('booktip').hidden = (cur !== config.home);
            render(d);
        }).catch(function (err) {
            if (my !== seq) return;
            say('列表失败: ' + err);
        });
    }

    backBtn.onclick = function () {
        if (busy || !hist.length) return;
        load(hist.pop(), true);
    };

    config.shortcuts.forEach(function (s) {
        var b = document.createElement('button');
        b.type = 'button';
        b.textContent = s.label;
        b.onclick = function () {
            if (!busy) load(s.path);
        };
        el('quick').appendChild(b);
    });

    upBtn.onclick = function () {
        var fs = fileInput.files;
        if (!fs.length || busy) return;
        setBusy(true);
        var i = 0;
        (function next() {
            if (i >= fs.length) {
                say('全部完成');
                setBusy(false);
                fileInput.value = '';
                load(cur, true);
                return;
            }
            var f = fs[i++];
            say('上传 ' + f.name + ' (' + fmt(f.size) + ')… ');
            jfetch(
                '/upload?dir=' + encodeURIComponent(cur) +
                '&name=' + encodeURIComponent(f.name),
                { method: 'PUT', body: f }
            ).then(function () {
                el('log').textContent += '成功\n';
                next();
            }).catch(function (err) {
                el('log').textContent += '失败: ' + err + '\n';
                next();
            });
        })();
    };

    mkBtn.onclick = function () {
        if (busy) return;
        dialog({ title: '新建文件夹', input: '', ok: '创建' }).then(function (n) {
            if (!n) return;
            var p = join(cur, n);
            jfetch('/api/mkdir?path=' + encodeURIComponent(p), {
                method: 'POST'
            }).then(function () {
                load(cur, true);
            }).catch(function (err) {
                say('新建失败: ' + err);
            });
        });
    };

    load(cur, true);
}).catch(function (err) {
    el('path').textContent = '配置加载失败: ' + err;
});
