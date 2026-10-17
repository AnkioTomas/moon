/* 订阅管理：分组侧栏（计数 / 新建 / 改名 / 删除 / 拖入）、订阅列表（搜索 / 排序 / 组内拖拽排序 / 多选批量）、
   添加与编辑对话框（试拉预览）、文章浏览（已读状态 + 正文预览）、批量刷新进度、OPML 导入导出。
   接口：/api/subscribe/<action>，失败回 {error}。文案全部走 t()，由 /api/i18n 翻译。 */
(function () {
    var API = '/api/subscribe/';
    var KIND = { rss: 'RSS', site: '网站', page: '网页', mp: '公众号' };
    var ALL = '\u0000all';
    var data = { feeds: [], groups: [], enabled: true };
    var cur = ALL;
    var sel = {};
    var stopRefresh = false;

    // 设备端 JSON 编码把空数组编成 {}：列表字段统一修正成 []，否则 .some/.forEach 直接抛错。
    var LISTS = ['feeds', 'groups', 'items', 'add', 'remove', 'rename', 'move', 'invalid', 'failed', 'added', 'entries'];
    function fixLists(v) {
        if (Array.isArray(v)) { v.forEach(fixLists); return v; }
        if (v && typeof v === 'object') {
            Object.keys(v).forEach(function (k) {
                if (LISTS.indexOf(k) >= 0 && !Array.isArray(v[k]) && v[k] && typeof v[k] === 'object' && !Object.keys(v[k]).length) v[k] = [];
                else fixLists(v[k]);
            });
        }
        return v;
    }
    function get(action, q) {
        var qs = q ? '?' + Object.keys(q).map(function (k) { return k + '=' + encodeURIComponent(q[k]); }).join('&') : '';
        return jfetch(API + action + qs).then(fixLists);
    }
    function post(action, body) {
        return jfetch(API + action, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) }).then(fixLists);
    }
    function errText(e) { return (e && e.message) || String(e); }
    function toast(text, kind) {
        var n = document.createElement('div');
        n.className = 'sub-toast' + (kind ? ' ' + kind : '');
        n.textContent = text;
        el('toasts').appendChild(n);
        setTimeout(function () { n.remove(); }, kind === 'err' ? 6000 : 3000);
    }
    function fail(e) { toast(t('操作失败：%1', errText(e)), 'err'); }
    function mk(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }
    function ago(ts) {
        if (!ts) return t('从未更新');
        var s = Math.max(0, Date.now() / 1000 - ts);
        if (s < 60) return t('刚刚');
        if (s < 3600) return t('%1 分钟前', Math.floor(s / 60));
        if (s < 86400) return t('%1 小时前', Math.floor(s / 3600));
        if (s < 86400 * 30) return t('%1 天前', Math.floor(s / 86400));
        return fmtT(ts).slice(0, 10);
    }
    function feedById(id) { for (var i = 0; i < data.feeds.length; i++) if (data.feeds[i].id === id) return data.feeds[i]; }
    function selectedIds() { return Object.keys(sel).map(Number).filter(feedById); }

    // ── 加载 ──
    function load() {
        return get('list').then(function (d) {
            data = d;
            data.groups = d.groups || [];
            el('banner').hidden = d.enabled !== false;
            el('banner').textContent = d.enabled === false ? t('设备上的订阅功能未开启，开启后才会在月读里显示：设置 → 订阅 → 启用订阅。') : '';
            if (cur !== ALL && cur !== '' && !data.groups.some(function (g) { return g.name === cur; })) cur = ALL;
            render();
        }).catch(function (e) {
            el('list').innerHTML = '';
            var tr = mk('tr'), td = mk('td', 'empty');
            td.colSpan = 8;
            td.textContent = t('读取失败：%1', errText(e));
            tr.appendChild(td);
            el('list').appendChild(tr);
        });
    }

    // ── 分组侧栏 ──
    function groupButton(key, name, count, unread, editable) {
        var b = mk('button');
        b.type = 'button';
        if (key === ALL) b.setAttribute('data-all', '');
        b.className = cur === key ? 'active' : '';
        var gn = mk('span', 'g-name', name);
        if (key !== ALL && key !== '') gn.setAttribute('translate', 'no');
        b.appendChild(gn);
        if (unread) b.appendChild(mk('span', 'g-unread', String(unread)));
        b.appendChild(mk('span', 'g-count', String(count)));
        if (editable) {
            var more = mk('span', 'g-more', '⋯');
            more.setAttribute('role', 'button');
            more.title = t('管理分组');
            more.onclick = function (e) { e.stopPropagation(); groupMenu(key); };
            b.appendChild(more);
        }
        b.onclick = function () { cur = key; sel = {}; render(); };
        if (key !== ALL) {
            b.ondragover = function (e) { if (dragId != null) { e.preventDefault(); b.classList.add('drop-target'); } };
            b.ondragleave = function () { b.classList.remove('drop-target'); };
            b.ondrop = function (e) {
                e.preventDefault();
                b.classList.remove('drop-target');
                var ids = sel[dragId] ? selectedIds() : [dragId];
                moveTo(ids, key);
            };
        }
        return b;
    }
    function renderGroups() {
        var box = el('groups');
        box.textContent = '';
        var unread = 0, ungrouped = 0, ungroupedUnread = 0;
        data.feeds.forEach(function (f) {
            unread += f.unread;
            if (!f.group) { ungrouped++; ungroupedUnread += f.unread; }
        });
        box.appendChild(groupButton(ALL, t('全部订阅'), data.feeds.length, unread));
        data.groups.forEach(function (g) { box.appendChild(groupButton(g.name, g.name, g.count, g.unread, true)); });
        box.appendChild(groupButton('', t('未分组'), ungrouped, ungroupedUnread));
        var dl = el('group-names');
        dl.textContent = '';
        data.groups.forEach(function (g) { var o = mk('option'); o.value = g.name; dl.appendChild(o); });
    }
    function groupMenu(name) {
        dialog({ title: t('分组「%1」', name), choices: [
            { text: t('重命名'), value: 'rename' },
            { text: t('删除分组'), value: 'delete', kind: 'danger' }
        ] }).then(function (v) {
            if (v === 'rename') {
                return dialog({ title: t('重命名分组'), input: name, ok: t('保存') }).then(function (to) {
                    to = (to || '').trim();
                    if (!to || to === name) return;
                    return post('group', { op: 'rename', name: name, to: to }).then(function () {
                        if (cur === name) cur = to;
                        toast(t('已重命名为「%1」', to));
                        return load();
                    });
                });
            }
            if (v === 'delete') {
                return dialog({ title: t('删除分组「%1」？', name), msg: t('组内的订阅会移到「未分组」，不会被删除。'), ok: t('删除'), danger: true }).then(function (ok) {
                    if (!ok) return;
                    return post('group', { op: 'delete', name: name }).then(function () {
                        if (cur === name) cur = ALL;
                        toast(t('分组已删除'));
                        return load();
                    });
                });
            }
        }).catch(fail);
    }
    el('new-group').onclick = function () {
        dialog({ title: t('新建分组'), input: '', ok: t('创建') }).then(function (name) {
            name = (name || '').trim();
            if (!name) return;
            return post('group', { op: 'create', name: name }).then(function () {
                cur = name;
                toast(t('已创建分组「%1」', name));
                return load();
            });
        }).catch(fail);
    };

    // ── 订阅列表 ──
    function visible() {
        var q = el('q').value.trim().toLowerCase();
        var list = data.feeds.filter(function (f) {
            if (cur !== ALL && (f.group || '') !== cur) return false;
            return !q || f.title.toLowerCase().indexOf(q) >= 0 || f.url.toLowerCase().indexOf(q) >= 0;
        });
        var key = el('sort').value;
        if (key === 'title') list.sort(function (a, b) { return a.title.localeCompare(b.title); });
        else if (key === 'unread') list.sort(function (a, b) { return b.unread - a.unread; });
        else if (key === 'updated') list.sort(function (a, b) { return b.updated_at - a.updated_at; });
        return list;
    }
    function canReorder() { return el('sort').value === 'manual' && cur !== ALL && !el('q').value.trim(); }
    var dragId = null;
    function row(f, reorder) {
        var tr = mk('tr');
        tr.dataset.id = f.id;
        tr.draggable = true;
        if (sel[f.id]) tr.className = 'selected';
        var tdSel = mk('td', 'sel'), cb = mk('input');
        cb.type = 'checkbox';
        cb.checked = !!sel[f.id];
        cb.setAttribute('aria-label', t('选择 %1', f.title));
        cb.onchange = function () { if (cb.checked) sel[f.id] = true; else delete sel[f.id]; tr.className = cb.checked ? 'selected' : ''; renderBatch(); };
        tdSel.appendChild(cb);
        tr.appendChild(tdSel);
        var handle = mk('td', 'handle', reorder ? '⋮⋮' : '');
        handle.title = reorder ? t('拖动排序') : '';
        tr.appendChild(handle);
        var tdIco = mk('td', 'ico'), ico = mk('span', 'sub-icon ' + f.kind, (f.title || '?').charAt(0).toUpperCase());
        ico.setAttribute('translate', 'no');
        tdIco.appendChild(ico);
        tr.appendChild(tdIco);
        var tdN = mk('td', 'n');
        var title = mk('span', 'f-title', f.title);
        title.setAttribute('translate', 'no');
        title.onclick = function () { openArticles(f); };
        var url = mk('span', 'f-url', f.url);
        url.setAttribute('translate', 'no');
        tdN.appendChild(title);
        tdN.appendChild(url);
        if (f.error) {
            var er = mk('span', 'f-err', t('上次刷新失败：%1', f.error));
            tdN.appendChild(er);
        }
        tr.appendChild(tdN);
        var tdK = mk('td', 'meta kind');
        tdK.appendChild(mk('span', 'sub-badge', t(KIND[f.kind] || f.kind)));
        tr.appendChild(tdK);
        var tdU = mk('td', 'meta unr');
        if (f.unread) { var u = mk('span', 'sub-unread', String(f.unread)); u.title = t('%1 篇未读', f.unread); tdU.appendChild(u); }
        tr.appendChild(tdU);
        tr.appendChild(mk('td', 'meta upd', ago(f.updated_at)));
        var ops = mk('td', 'ops');
        var bRef = mk('button', 'btn-outline', t('刷新'));
        bRef.type = 'button';
        bRef.onclick = function () { refreshIds([f.id]); };
        var bEdit = mk('button', 'btn-outline op-edit', t('编辑'));
        bEdit.type = 'button';
        bEdit.onclick = function () { openFeedDialog(f); };
        var bDel = mk('button', 'btn-outline danger-text', t('删除'));
        bDel.type = 'button';
        bDel.onclick = function () { removeIds([f.id]); };
        ops.appendChild(bRef); ops.appendChild(bEdit); ops.appendChild(bDel);
        tr.appendChild(ops);

        tr.ondragstart = function (e) { dragId = f.id; tr.classList.add('dragging'); e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', String(f.id)); };
        tr.ondragend = function () { dragId = null; tr.classList.remove('dragging'); clearDrop(); };
        if (reorder) {
            tr.ondragover = function (e) { if (dragId != null && dragId !== f.id) { e.preventDefault(); clearDrop(); tr.classList.add('drop-before'); } };
            tr.ondrop = function (e) {
                e.preventDefault();
                clearDrop();
                if (dragId == null || dragId === f.id) return;
                var ids = visible().map(function (x) { return x.id; }).filter(function (id) { return id !== dragId; });
                ids.splice(ids.indexOf(f.id), 0, dragId);
                reorderGroup(ids);
            };
        }
        return tr;
    }
    function clearDrop() {
        var n = document.querySelectorAll('.drop-before');
        for (var i = 0; i < n.length; i++) n[i].classList.remove('drop-before');
    }
    function emptyRow(title, sub, action) {
        var tr = mk('tr'), td = mk('td', 'empty sub-empty');
        td.colSpan = 8;
        td.appendChild(mk('strong', null, title));
        if (sub) td.appendChild(mk('span', null, sub));
        if (action) {
            var b = mk('button', 'primary', action.text);
            b.type = 'button';
            b.onclick = action.fn;
            td.appendChild(mk('br'));
            td.appendChild(b);
        }
        tr.appendChild(td);
        return tr;
    }
    function render() {
        renderGroups();
        var body = el('list');
        body.textContent = '';
        var list = visible();
        var reorder = canReorder();
        if (!data.feeds.length) {
            body.appendChild(emptyRow(t('还没有订阅'), t('添加 RSS 或任意网站，也可以导入 OPML。微信读书书架上的公众号会自动加入。'), { text: t('添加订阅'), fn: function () { openFeedDialog(); } }));
        } else if (!list.length) {
            body.appendChild(emptyRow(el('q').value.trim() ? t('没有匹配的订阅') : t('这个分组还是空的'), el('q').value.trim() ? '' : t('把左侧列表里的订阅拖到分组上，或用「移到分组」。')));
        } else {
            list.forEach(function (f) { body.appendChild(row(f, reorder)); });
        }
        renderBatch();
    }
    function renderBatch() {
        var ids = selectedIds();
        el('batch').hidden = !ids.length;
        el('batch-count').textContent = t('已选 %1 个', ids.length);
    }
    el('q').oninput = render;
    el('sort').onchange = render;
    el('b-clear').onclick = function () { sel = {}; render(); };
    el('b-delete').onclick = function () { removeIds(selectedIds()); };
    el('b-refresh').onclick = function () { refreshIds(selectedIds()); };
    el('b-move').onclick = function () {
        var choices = data.groups.map(function (g) { return { text: g.name, value: g.name }; });
        choices.push({ text: t('未分组'), value: '' });
        choices.push({ text: t('新建分组…'), value: ALL });
        dialog({ title: t('移到分组'), choices: choices }).then(function (v) {
            if (v == null) return;
            if (v !== ALL) return moveTo(selectedIds(), v);
            return dialog({ title: t('新建分组'), input: '', ok: t('创建') }).then(function (name) {
                name = (name || '').trim();
                if (!name) return;
                return post('group', { op: 'create', name: name }).then(function () { return moveTo(selectedIds(), name); });
            });
        }).catch(fail);
    };

    function moveTo(ids, group) {
        if (!ids.length) return;
        return post('move', { ids: ids, group: group }).then(function () {
            toast(group ? t('已移动 %1 个订阅到「%2」', ids.length, group) : t('已移动 %1 个订阅到未分组', ids.length));
            sel = {};
            return load();
        }).catch(fail);
    }
    function reorderGroup(ids) {
        return post('reorder', { group: cur, ids: ids }).then(load).catch(fail);
    }
    function removeIds(ids) {
        if (!ids.length) return;
        var one = ids.length === 1 && feedById(ids[0]);
        dialog({
            title: one ? t('取消订阅「%1」？', one.title) : t('取消订阅选中的 %1 个订阅？', ids.length),
            msg: t('已缓存的文章一并删除。公众号取消后不会再自动加回。'),
            ok: t('删除'), danger: true
        }).then(function (ok) {
            if (!ok) return;
            return post('remove', { ids: ids }).then(function (r) {
                toast(t('已删除 %1 个订阅', r.removed));
                ids.forEach(function (id) { delete sel[id]; });
                return load();
            });
        }).catch(fail);
    }

    // ── 刷新（逐个，带进度） ──
    function refreshIds(ids) {
        if (!ids.length) return;
        stopRefresh = false;
        var done = 0, added = 0, failed = 0;
        var prog = el('prog');
        prog.hidden = false;
        prog.className = 'overlay up-overlay on';
        function step() {
            if (stopRefresh || done >= ids.length) return finish();
            var f = feedById(ids[done]);
            el('pg-name').textContent = f ? f.title : '';
            el('pg-fill').style.width = Math.round(done * 100 / ids.length) + '%';
            el('pg-stats').textContent = done + ' / ' + ids.length;
            return post('refresh', { id: ids[done] }).then(function (r) { added += r.added || 0; })
                .catch(function () { failed++; })
                .then(function () { done++; return step(); });
        }
        function finish() {
            prog.hidden = true;
            prog.className = 'overlay up-overlay';
            var msg = t('刷新完成：新增 %1 篇', added);
            if (failed) msg = t('刷新完成：新增 %1 篇，%2 个失败', added, failed);
            toast(msg, failed ? 'err' : '');
            return load();
        }
        step();
    }
    el('pg-cancel').onclick = function () { stopRefresh = true; };
    el('refresh-all').onclick = function () { refreshIds(visible().map(function (f) { return f.id; })); };

    // ── 添加 / 编辑对话框 ──
    var editing = null;
    var checked = null;
    function kindValue() { var r = document.querySelector('input[name=kind]:checked'); return r ? r.value : 'rss'; }
    function fdState(text, kind) { setState(el('fd-state'), text, kind); }
    function openFeedDialog(f) {
        editing = f || null;
        checked = null;
        var ov = el('feed-dlg');
        el('fd-title').textContent = f ? t('编辑订阅') : t('添加订阅');
        el('fd-ok').textContent = f ? t('保存') : t('添加');
        el('fd-kinds').hidden = !!f;
        el('fd-test').hidden = !!f;
        el('fd-url').value = f ? f.url : '';
        el('fd-url').readOnly = !!f;
        el('fd-name').value = f ? f.title : '';
        el('fd-group').value = f ? f.group : (cur !== ALL ? cur : '');
        el('fd-kind-note').hidden = !(f && f.kind === 'mp');
        el('fd-preview').hidden = true;
        el('fd-preview').textContent = '';
        fdState('');
        ov.hidden = false;
        ov.className = 'overlay up-overlay on';
        (f ? el('fd-name') : el('fd-url')).focus();
    }
    function closeFeedDialog() { var ov = el('feed-dlg'); ov.hidden = true; ov.className = 'overlay up-overlay'; }
    el('fd-cancel').onclick = closeFeedDialog;
    el('feed-dlg').onclick = function (e) { if (e.target === el('feed-dlg')) closeFeedDialog(); };
    document.addEventListener('keydown', function (e) {
        if (e.key !== 'Escape') return;
        if (!el('feed-dlg').hidden) closeFeedDialog();
        else if (!el('plan').hidden) closePlan();
        else if (!el('bulk').hidden) closeBulk();
        else if (!el('articles').hidden) closeArticles();
    });
    el('fd-url').oninput = function () { checked = null; };
    Array.prototype.forEach.call(document.querySelectorAll('input[name=kind]'), function (r) { r.onchange = function () { checked = null; }; });
    function renderPreview(p) {
        var box = el('fd-preview');
        box.textContent = '';
        box.appendChild(mk('h3', null, p.title)).setAttribute('translate', 'no');
        if (p.url !== el('fd-url').value.trim()) box.appendChild(mk('div', 'sheet-note', t('已找到订阅源：%1', p.url)));
        if (p.items && p.items.length) {
            box.appendChild(mk('div', 'sheet-note', t('最近的文章')));
            var ol = mk('ol');
            ol.setAttribute('translate', 'no');
            p.items.forEach(function (it) { ol.appendChild(mk('li', null, it.title || it.link)); });
            box.appendChild(ol);
        }
        if (p.excerpt) {
            box.appendChild(mk('div', 'sheet-note', t('正文提取预览')));
            box.appendChild(mk('blockquote', null, p.excerpt)).setAttribute('translate', 'no');
        } else if (p.excerpt_error) {
            box.appendChild(mk('div', 'state err', t('正文提取失败：%1', p.excerpt_error)));
        }
        box.hidden = false;
    }
    // 粘进来的是 OPML 订阅列表：不当成单个订阅，给一个「全部导入」按钮。
    function offerOpml(p) {
        checked = null;
        var box = el('fd-preview');
        box.textContent = '';
        box.appendChild(mk('div', 'sheet-note', t('这是 OPML 订阅列表，共 %1 个订阅。', p.count)));
        var b = mk('button', 'primary', t('全部导入'));
        b.type = 'button';
        b.onclick = function () {
            b.disabled = true;
            importOpml({ url: p.url }).then(function (ok) { if (ok) closeFeedDialog(); else b.disabled = false; });
        };
        box.appendChild(b);
        box.hidden = false;
        fdState(t('这是 OPML 订阅列表'), 'ok');
    }
    function test() {
        var url = el('fd-url').value.trim();
        if (!url) { fdState(t('请填写订阅地址'), 'err'); return Promise.resolve(null); }
        fdState(t('正在测试…'));
        el('fd-test').disabled = el('fd-ok').disabled = true;
        return post('preview', { kind: kindValue(), url: url }).then(function (p) {
            if (p.opml) { offerOpml(p); return null; }
            checked = p;
            renderPreview(p);
            if (!el('fd-name').value.trim()) el('fd-name').placeholder = p.title;
            fdState(t('可以订阅 ✓'), 'ok');
            return p;
        }).catch(function (e) {
            el('fd-preview').hidden = true;
            fdState(t('测试失败：%1', errText(e)), 'err');
            return null;
        }).then(function (p) { el('fd-test').disabled = el('fd-ok').disabled = false; return p; });
    }
    el('fd-test').onclick = test;
    el('feed-form').onsubmit = function (e) {
        e.preventDefault();
        if (editing) {
            return post('update', { id: editing.id, title: el('fd-name').value.trim(), group: el('fd-group').value.trim() })
                .then(function () { closeFeedDialog(); toast(t('已保存')); return load(); })
                .catch(function (err) { fdState(errText(err), 'err'); });
        }
        (checked ? Promise.resolve(checked) : test()).then(function (p) {
            if (!p) return;
            fdState(t('正在添加…'));
            return post('add', {
                kind: p.kind, url: p.url, checked: true, title: el('fd-name').value.trim() || p.title,
                group: el('fd-group').value.trim()
            }).then(function () {
                closeFeedDialog();
                toast(t('已添加「%1」', el('fd-name').value.trim() || p.title));
                return load();
            });
        }).catch(function (err) { fdState(errText(err), 'err'); });
    };
    el('add').onclick = function () { openFeedDialog(); };

    // ── 文章浏览 ──
    var arFeed = null, arPage = 1, arItems = [];
    function openArticles(f) {
        arFeed = f; arPage = 1; arItems = [];
        el('ar-title').textContent = f.title;
        el('ar-body').hidden = true;
        el('ar-hint').hidden = false;
        el('ar-hint').textContent = t('选择一篇文章预览');
        el('articles').hidden = false;
        loadArticles();
    }
    function closeArticles() { el('articles').hidden = true; arFeed = null; load(); }
    el('ar-close').onclick = closeArticles;
    el('ar-filter').onchange = function () { arPage = 1; arItems = []; loadArticles(); };
    function loadArticles() {
        var list = el('ar-list');
        if (arPage === 1) { list.textContent = ''; list.appendChild(mk('li', 'empty', t('正在加载…'))); }
        var q = { id: arFeed.id, page: arPage };
        if (el('ar-filter').value !== '') q.read = el('ar-filter').value;
        return get('items', q).then(function (r) {
            arItems = arItems.concat(r.items);
            list.textContent = '';
            el('ar-count').textContent = t('共 %1 篇', r.total);
            if (!arItems.length) list.appendChild(mk('li', 'empty', t('还没有文章，点「刷新」拉取')));
            arItems.forEach(function (it) { list.appendChild(articleRow(it)); });
            if (arItems.length < r.total) {
                var more = mk('li', 'more', t('加载更多'));
                more.onclick = function () { arPage++; loadArticles(); };
                list.appendChild(more);
            }
        }).catch(function (e) { list.textContent = ''; list.appendChild(mk('li', 'empty', t('读取失败：%1', errText(e)))); });
    }
    function articleRow(it) {
        var li = mk('li', it.read ? 'read' : '');
        var title = mk('span', 'a-title', it.title || it.link);
        title.setAttribute('translate', 'no');
        li.appendChild(title);
        li.appendChild(mk('span', 'a-time', it.time ? fmtT(it.time) : (it.read ? t('已读') : t('未读'))));
        li.onclick = function () {
            var act = document.querySelectorAll('.sub-art-list li.active');
            for (var i = 0; i < act.length; i++) act[i].classList.remove('active');
            li.classList.add('active');
            showArticle(it, li);
        };
        return li;
    }
    // 正文直接插进阅读区：服务端已按白名单清洗，这里再用 DOMParser 按同一份白名单过一遍（解析时脚本不执行），
    // 只留排版标签，属性只留 a 的 http(s) href、表格跨行列、img 的 https / data:image 地址（不带 Referer）。
    var ART_TAGS = ('p br hr h1 h2 h3 h4 h5 h6 div span section article header footer blockquote pre code ul ol li dl dt dd '
        + 'strong b em i u s del ins sub sup small mark a table thead tbody tfoot tr th td caption figure figcaption img').split(' ');
    var ART_DROP = /^(script|style|iframe|object|embed|video|audio|noscript|template|svg|math|textarea|select|button|form|canvas|link|meta|base|input|frame|frameset)$/;
    function safeNodes(src, dst) {
        for (var n = src.firstChild; n; n = n.nextSibling) {
            if (n.nodeType === 3) { dst.appendChild(document.createTextNode(n.nodeValue)); continue; }
            if (n.nodeType !== 1) continue;
            var tag = n.nodeName.toLowerCase();
            if (ART_DROP.test(tag)) continue;
            if (ART_TAGS.indexOf(tag) < 0) { safeNodes(n, dst); continue; }
            var c = document.createElement(tag);
            if (tag === 'img') {
                var src = (n.getAttribute('src') || '').replace(/[\s\u0000-\u001f]/g, '');
                if (!/^https:\/\//i.test(src) && !/^data:image\/(?!svg)[\w.+-]+;base64,/i.test(src)) continue;
                c.referrerPolicy = 'no-referrer';
                c.loading = 'lazy';
                c.alt = '';
                c.src = src;
                dst.appendChild(c);
                continue;
            }
            if (tag === 'a') {
                var href = n.getAttribute('href') || '';
                if (/^https?:\/\//i.test(href.replace(/[\s\u0000-\u001f]/g, ''))) { c.href = href; c.target = '_blank'; c.rel = 'noopener noreferrer'; }
            } else if (tag === 'td' || tag === 'th') {
                ['colspan', 'rowspan'].forEach(function (k) { var v = n.getAttribute(k); if (/^\d+$/.test(v || '')) c.setAttribute(k, v); });
            }
            safeNodes(n, c);
            dst.appendChild(c);
        }
    }
    function showArticle(it, li) {
        var body = el('ar-body');
        body.hidden = true;
        el('ar-hint').hidden = false;
        el('ar-hint').textContent = t('正在获取正文…');
        post('article', { id: arFeed.id, guid: it.guid }).then(function (a) {
            var doc = new DOMParser().parseFromString(a.html || '', 'text/html');
            body.textContent = '';
            safeNodes(doc.body, body);
            body.scrollTop = 0;
            body.hidden = false;
            el('ar-hint').hidden = true;
            if (!it.read) {
                it.read = true;
                li.classList.add('read');
                post('read', { id: arFeed.id, guid: it.guid }).catch(function () {});
            }
        }).catch(function (e) { el('ar-hint').textContent = t('正文获取失败：%1', errText(e)); });
    }
    el('ar-readall').onclick = function () {
        post('read', { id: arFeed.id }).then(function () {
            arItems.forEach(function (it) { it.read = true; });
            var lis = document.querySelectorAll('.sub-art-list li');
            for (var i = 0; i < lis.length; i++) if (!lis[i].classList.contains('more')) lis[i].classList.add('read');
            toast(t('已全部标为已读'));
        }).catch(fail);
    };
    el('ar-refresh').onclick = function () {
        el('ar-refresh').disabled = true;
        post('refresh', { id: arFeed.id }).then(function (r) {
            toast(t('新增 %1 篇', r.added));
            arPage = 1; arItems = [];
            return loadArticles();
        }).catch(fail).then(function () { el('ar-refresh').disabled = false; });
    };

    // ── OPML ──
    function importOpml(body) {
        toast(t('正在导入…'));
        return post('import', body).then(function (r) {
            return dialog({ title: t('导入完成'), msg: t('共 %1 个订阅：新增 %2 个，已存在跳过 %3 个。', r.total, r.added, r.skipped), ok: t('好') })
                .then(load).then(function () { return true; });
        }).catch(function (e) { toast(t('导入失败：%1', errText(e)), 'err'); return false; });
    }
    el('import').onclick = function () {
        dialog({ title: t('导入 OPML'), choices: [
            { text: t('从文件'), value: 'file', kind: 'primary' },
            { text: t('从网址'), value: 'url' }
        ] }).then(function (v) {
            if (v === 'file') return el('import-file').click();
            if (v !== 'url') return;
            return dialog({ title: t('OPML 网址'), input: '', ok: t('导入') }).then(function (url) {
                url = (url || '').trim();
                if (url) return importOpml({ url: url });
            });
        });
    };
    el('import-file').onchange = function () {
        var file = this.files[0];
        this.value = '';
        if (!file) return;
        file.text().then(function (text) { return importOpml({ opml: text }); });
    };

    // ── 纯文本批量编辑 ──
    var bulkOrig = '';
    function openBulk() {
        el('bulk').hidden = false;
        el('bk-text').value = t('正在加载…');
        el('bk-text').disabled = true;
        get('text').then(function (r) {
            bulkOrig = r.text;
            el('bk-text').value = r.text;
            el('bk-text').disabled = false;
            el('bk-text').focus();
        }).catch(function (e) { el('bk-text').value = ''; toast(t('读取失败：%1', errText(e)), 'err'); });
    }
    function closeBulk(force) {
        if (!force && el('bk-text').value !== bulkOrig) {
            return dialog({ title: t('放弃未应用的修改？'), ok: t('放弃'), danger: true }).then(function (ok) { if (ok) closeBulk(true); });
        }
        el('bulk').hidden = true;
    }
    el('bulk-open').onclick = openBulk;
    el('bk-close').onclick = function () { closeBulk(); };
    el('bk-reset').onclick = function () { el('bk-text').value = bulkOrig; };
    function section(box, title, list, fmtItem, cls) {
        if (!list.length) return;
        box.appendChild(mk('h3', null, t(title, list.length)));
        var ul = mk('ul', cls);
        ul.setAttribute('translate', 'no');
        list.forEach(function (x) { ul.appendChild(mk('li', null, fmtItem(x))); });
        box.appendChild(ul);
    }
    function showPlan(p) {
        var box = el('pl-body');
        box.textContent = '';
        setState(el('pl-state'), '');
        var n = p.add.length + p.remove.length + p.rename.length + p.move.length;
        if (!n) box.appendChild(mk('p', null, t('没有变更。')));
        section(box, '新增 %1 个（自动识别标题和类型）', p.add, function (x) { return (x.title ? x.title + ' · ' : '') + x.url + (x.group ? ' → ' + x.group : ''); }, 'add');
        section(box, '删除 %1 个', p.remove, function (x) { return x.title; }, 'del');
        section(box, '改名 %1 个', p.rename, function (x) { return x.from + ' → ' + x.to; });
        section(box, '移动分组 %1 个', p.move, function (x) { return x.title + ': ' + (x.from || t('未分组')) + ' → ' + (x.to || t('未分组')); });
        section(box, '无法识别的行 %1 个（将被忽略）', p.invalid, function (x) { return t('第 %1 行：%2', x.line, x.text); }, 'del');
        section(box, '重复的地址 %1 个（只保留第一次出现）', p.duplicate, function (x) { return t('第 %1 行：%2', x.line, x.url); });
        el('pl-ok').disabled = !n && !p.invalid.length;
        var ov = el('plan');
        ov.hidden = false;
        ov.className = 'overlay up-overlay on';
    }
    function closePlan() { el('plan').hidden = true; el('plan').className = 'overlay up-overlay'; }
    el('pl-cancel').onclick = closePlan;
    el('bk-preview').onclick = function () {
        el('bk-preview').disabled = true;
        post('batch', { text: el('bk-text').value }).then(showPlan).catch(fail)
            .then(function () { el('bk-preview').disabled = false; });
    };
    el('pl-ok').onclick = function () {
        el('pl-ok').disabled = el('pl-cancel').disabled = true;
        setState(el('pl-state'), t('正在应用，新地址需要逐个识别，请稍候…'));
        post('batch', { text: el('bk-text').value, apply: true }).then(function (r) {
            closePlan();
            closeBulk(true);
            var msg = t('已应用：新增 %1，删除 %2，改名 %3，移动 %4。', r.added, r.removed, r.renamed, r.moved);
            if (r.failed.length) {
                return dialog({ title: t('部分地址未能添加'), msg: msg + '\n' + r.failed.map(function (f) { return f.url + ': ' + f.error; }).join('\n'), ok: t('好') });
            }
            toast(msg);
        }).catch(function (e) { setState(el('pl-state'), t('应用失败：%1', errText(e)), 'err'); })
            .then(function () { el('pl-ok').disabled = el('pl-cancel').disabled = false; return load(); });
    };

    load();
})();
