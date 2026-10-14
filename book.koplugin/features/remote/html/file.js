/* 文件管理页面逻辑（依赖 /js.js 共享函数与 /api/config）。
   功能：多标签、面包屑/路径输入、排序、隐藏文件、多选与批量操作、复制/剪切/粘贴（冲突处理）、
   重命名、新建文件/文件夹、删除、属性、打包下载、解压、上传队列（进度/取消/重试/拖放）、
   文本编辑器（搜索替换/编码/换行符/跳转）、图片音视频预览、右键/长按菜单与键盘快捷键。 */
loadConfig().then(function (config) {
    var STORE = 'moon-fm-';
    var TEXT_EXT = /\.(txt|md|markdown|lua|json|js|css|html?|xml|csv|tsv|log|ini|conf|cfg|ya?ml|toml|sh|py|srt|ass|ssa|vtt|opf|ncx|svg|properties|tex|rst|c|h|cpp|java|go|rs|ts|sql|gitignore|env)$/i;
    var IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp)$/i;
    var VIDEO_EXT = /\.(mp4|m4v|webm)$/i;
    var AUDIO_EXT = /\.(mp3|m4a|ogg|wav|flac)$/i;
    var EDIT_LIMIT = 4 * 1024 * 1024;

    var cur = config.home;
    var hist = [];
    var seq = 0;
    var busy = false;
    var parentPath = null;
    var entries = [];
    var shown = [];
    var selected = {};
    var cursor = -1;
    var anchor = -1;
    var clip = null;

    var backBtn = el('back');
    var parentBtn = el('parent');
    var refreshBtn = el('refresh');
    var pickFileBtn = el('pickfile');
    var pickFolderBtn = el('pickfolder');
    var mkBtn = el('mk');
    var fileInput = el('file');
    var folderInput = el('folder');
    var explorerContent = document.querySelector('.explorer-content');
    var dropzone = el('dropzone');
    var listWrap = el('listwrap');

    function getPref(key, def) {
        try {
            var v = localStorage.getItem(STORE + key);
            return v == null ? def : JSON.parse(v);
        } catch (e) { return def; }
    }
    function setPref(key, v) {
        try { localStorage.setItem(STORE + key, JSON.stringify(v)); } catch (e) {}
    }
    var prefs = {
        sort: getPref('sort', { by: 'name', reverse: false }),
        folderSort: getPref('folder-sort', {}),
        showSystemHidden: getPref('show-system-hidden', false),
        showManualHidden: getPref('show-manual-hidden', false),
        hidden: getPref('hidden', [])
    };

    function setBusy(on) {
        busy = on;
        pickFileBtn.disabled = on;
        pickFolderBtn.disabled = on;
        mkBtn.disabled = on;
        refreshBtn.disabled = on;
        fileInput.disabled = on;
        folderInput.disabled = on;
        backBtn.disabled = on || hist.length === 0;
        parentBtn.disabled = on || !parentPath;
        var buttons = el('quick').getElementsByTagName('button');
        for (var i = 0; i < buttons.length; i++) buttons[i].disabled = on;
    }

    function join(dir, name) { return (dir === '/' ? '' : dir) + '/' + name; }
    function baseName(p) { return p.replace(/\/+$/, '').split('/').pop() || p; }
    function dirName(p) { var d = p.replace(/\/[^/]*$/, ''); return d || '/'; }
    function ext(name) { var m = /\.([^.\/]+)$/.exec(name); return m ? m[1].toLowerCase() : ''; }
    function post(url, body) {
        var opt = { method: 'POST' };
        if (body != null) opt.body = body;
        return jfetch(url, opt);
    }
    function q(params) {
        return Object.keys(params).filter(function (k) { return params[k] != null; }).map(function (k) {
            return k + '=' + encodeURIComponent(params[k]);
        }).join('&');
    }
    function errText(err) { return String(err && err.message ? err.message : err); }
    function copyText(text) {
        if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e) {}
        ta.remove();
        return Promise.resolve();
    }
    function toast(text) { say(text); }

    var sheet = el('sheet');
    var sheetKey = null;
    function openSheet(title, body, buttons) {
        el('sheet-title').textContent = title;
        var b = el('sheet-body');
        b.innerHTML = '';
        if (typeof body === 'string') b.textContent = body;
        else if (body) b.appendChild(body);
        var box = el('sheet-btns');
        box.innerHTML = '';
        return new Promise(function (resolve) {
            function close(v) {
                sheet.hidden = true;
                sheet.className = 'overlay sheet-overlay';
                document.removeEventListener('keydown', sheetKey);
                sheetKey = null;
                resolve(v);
            }
            (buttons || [{ text: '确定', value: true, kind: 'primary' }]).forEach(function (spec) {
                var btn = document.createElement('button');
                btn.type = 'button';
                btn.textContent = spec.text;
                if (spec.kind) btn.className = spec.kind;
                btn.onclick = function () { close(spec.value); };
                box.appendChild(btn);
            });
            sheet.onclick = function (e) { if (e.target === sheet) close(null); };
            sheetKey = function (e) { if (e.key === 'Escape') { e.preventDefault(); close(null); } };
            document.addEventListener('keydown', sheetKey);
            sheet.hidden = false;
            sheet.className = 'overlay sheet-overlay on';
            var last = box.lastChild;
            if (last) last.focus();
        });
    }
    function node(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }
    function radioGroup(name, options, value) {
        var wrap = node('div', 'opt-grid');
        options.forEach(function (o) {
            var label = node('label', 'opt');
            var input = document.createElement('input');
            input.type = 'radio';
            input.name = name;
            input.value = o[0];
            input.checked = o[0] === value;
            label.appendChild(input);
            label.appendChild(document.createTextNode(o[1]));
            wrap.appendChild(label);
        });
        return wrap;
    }
    function checkbox(text, checked) {
        var label = node('label', 'opt');
        var input = document.createElement('input');
        input.type = 'checkbox';
        input.checked = !!checked;
        label.appendChild(input);
        label.appendChild(document.createTextNode(text));
        return { label: label, input: input };
    }

    var tabs = getPref('tabs', null);
    var activeTab = getPref('active-tab', 0);
    if (!Array.isArray(tabs) || !tabs.length) { tabs = [config.home]; activeTab = 0; }
    if (activeTab >= tabs.length) activeTab = 0;
    cur = tabs[activeTab];
    function saveTabs() { setPref('tabs', tabs); setPref('active-tab', activeTab); }
    function range(a, b) { var r = []; for (var i = a; i < b; i++) r.push(i); return r; }
    function renderTabs() {
        var bar = el('tabs');
        bar.innerHTML = '';
        tabs.forEach(function (path, i) {
            var t = node('div', 'tab-item' + (i === activeTab ? ' active' : ''));
            t.setAttribute('role', 'tab');
            t.setAttribute('aria-selected', i === activeTab ? 'true' : 'false');
            t.title = path;
            var tl = node('span', 'tab-label', path === '/' ? '根目录' : baseName(path));
            if (path !== '/') tl.setAttribute('translate', 'no');
            t.appendChild(tl);
            if (tabs.length > 1) {
                var x = node('button', 'tab-close', '×');
                x.type = 'button';
                x.setAttribute('aria-label', '关闭标签');
                x.onclick = function (e) { e.stopPropagation(); closeTabs([i]); };
                t.appendChild(x);
            }
            t.onclick = function () { switchTab(i); };
            t.oncontextmenu = function (e) {
                e.preventDefault();
                openMenu(e.clientX, e.clientY, [
                    ['关闭标签', function () { closeTabs([i]); }, tabs.length < 2],
                    ['关闭其它', function () { closeTabs(range(0, tabs.length).filter(function (k) { return k !== i; })); }, tabs.length < 2],
                    ['关闭左边', function () { closeTabs(range(0, i)); }, i === 0],
                    ['关闭右边', function () { closeTabs(range(i + 1, tabs.length)); }, i === tabs.length - 1],
                    ['关闭全部', function () { tabs = [config.home]; activeTab = 0; saveTabs(); renderTabs(); hist = []; load(config.home, true); }]
                ]);
            };
            bar.appendChild(t);
        });
        var add = node('button', 'tab-add', '+');
        add.type = 'button';
        add.title = '新建标签';
        add.setAttribute('aria-label', '新建标签');
        add.onclick = newTab;
        bar.appendChild(add);
    }
    function newTab() { tabs.push(cur); activeTab = tabs.length - 1; saveTabs(); renderTabs(); }
    function switchTab(i) {
        if (busy || i === activeTab) return;
        activeTab = i;
        hist = [];
        saveTabs();
        renderTabs();
        load(tabs[i], true);
    }
    function closeTabs(list) {
        if (!list.length) return;
        var keep = [], newActive = 0;
        tabs.forEach(function (p, i) {
            if (list.indexOf(i) < 0) {
                if (i <= activeTab) newActive = keep.length;
                keep.push(p);
            }
        });
        if (!keep.length) keep = [config.home];
        newActive = Math.min(newActive, keep.length - 1);
        var changed = keep[newActive] !== cur;
        tabs = keep;
        activeTab = newActive;
        saveTabs();
        renderTabs();
        if (changed) { hist = []; load(tabs[activeTab], true); }
    }

    var pathInput = el('pathinput');
    function renderBreadcrumb() {
        var box = el('path');
        box.innerHTML = '';
        box.title = cur;
        var parts = cur.split('/').filter(Boolean);
        var acc = '';
        var root = node('button', 'crumb', '根目录');
        root.type = 'button';
        root.onclick = function (e) { e.stopPropagation(); load('/'); };
        box.appendChild(root);
        parts.forEach(function (p) {
            acc += '/' + p;
            box.appendChild(node('span', 'crumb-sep', '/'));
            var target = acc;
            var c = node('button', 'crumb', p);
            c.setAttribute('translate', 'no');
            c.type = 'button';
            c.onclick = function (e) { e.stopPropagation(); load(target); };
            box.appendChild(c);
        });
        fitCrumbs();
    }
    // 窄屏：从左侧开始把前面的层级折叠成“…”（点开即输入路径），保证当前目录完整可见。
    function fitCrumbs() {
        var box = el('path');
        var kids = Array.prototype.slice.call(box.children);
        kids.forEach(function (k) { k.hidden = false; });
        var old = box.querySelector('.crumb-more');
        if (old) old.remove();
        if (box.scrollWidth <= box.clientWidth + 1) return;
        var more = node('button', 'crumb crumb-more', '…');
        more.type = 'button';
        more.title = cur;
        more.setAttribute('aria-label', '显示完整路径');
        more.onclick = function (e) { e.stopPropagation(); editPath(); };
        box.insertBefore(more, box.firstChild);
        // kids: [根目录, sep, a, sep, b, ...]；保留最后一个层级及其前一个分隔符
        for (var i = 0; i < kids.length - 2 && box.scrollWidth > box.clientWidth + 1; i++) {
            kids[i].hidden = true;
        }
        box.scrollLeft = box.scrollWidth;
    }
    window.addEventListener('resize', function () { if (el('path').childNodes.length) fitCrumbs(); });
    // 软键盘弹出时可视区变矮：全屏编辑器高度跟随 visualViewport，状态栏和光标不被键盘挡住。
    if (window.visualViewport) {
        var syncVv = function () {
            document.documentElement.style.setProperty('--vvh', window.visualViewport.height + 'px');
        };
        window.visualViewport.addEventListener('resize', syncVv);
        syncVv();
    }
    function editPath() {
        pathInput.hidden = false;
        el('path').hidden = true;
        pathInput.value = cur;
        pathInput.focus();
        pathInput.select();
    }
    function endEditPath() { pathInput.hidden = true; el('path').hidden = false; }
    el('address').onclick = function (e) { if (e.target !== pathInput) editPath(); };
    pathInput.onkeydown = function (e) {
        if (e.key === 'Enter') {
            e.preventDefault();
            var v = pathInput.value.trim();
            endEditPath();
            if (v) load(v);
        } else if (e.key === 'Escape') { e.preventDefault(); endEditPath(); }
    };
    pathInput.onblur = endEditPath;

    function sortSpec() { return prefs.folderSort[cur] || prefs.sort; }
    function isManualHidden(path) { return prefs.hidden.indexOf(path) >= 0; }
    function visible(e) {
        if (!prefs.showSystemHidden && e.name.charAt(0) === '.') return false;
        if (!prefs.showManualHidden && isManualHidden(join(cur, e.name))) return false;
        return true;
    }
    function compare(spec) {
        var dir = spec.reverse ? -1 : 1;
        return function (a, b) {
            if (a.dir !== b.dir) return a.dir ? -1 : 1;
            var r = 0;
            if (spec.by === 'size') r = (a.size || 0) - (b.size || 0);
            else if (spec.by === 'date') r = (a.mtime || 0) - (b.mtime || 0);
            else if (spec.by === 'type') r = ext(a.name).localeCompare(ext(b.name));
            if (r === 0) r = a.name.localeCompare(b.name, 'zh-CN', { numeric: true, sensitivity: 'base' });
            return r * dir;
        };
    }
    function openSort() {
        var spec = sortSpec();
        var body = node('div');
        var group = radioGroup('sortby', [['name', '按名称'], ['size', '按大小'], ['date', '按日期'], ['type', '按类型']], spec.by);
        body.appendChild(group);
        var rev = checkbox('反向排序', spec.reverse);
        var only = checkbox('仅应用于此文件夹', !!prefs.folderSort[cur]);
        body.appendChild(rev.label);
        body.appendChild(only.label);
        openSheet('排序方式', body, [
            { text: '取消', value: null },
            { text: '确定', value: true, kind: 'primary' }
        ]).then(function (ok) {
            if (!ok) return;
            var next = { by: group.querySelector('input:checked').value, reverse: rev.input.checked };
            if (only.input.checked) prefs.folderSort[cur] = next;
            else { delete prefs.folderSort[cur]; prefs.sort = next; setPref('sort', next); }
            setPref('folder-sort', prefs.folderSort);
            render();
        });
    }
    function editHidden() {
        var body = node('div');
        body.appendChild(node('p', 'sheet-note', '每行一个绝对路径；非 / 开头的行会被忽略。'));
        var ta = document.createElement('textarea');
        ta.className = 'hidden-files-textarea';
        ta.rows = 10;
        ta.value = prefs.hidden.join('\n');
        body.appendChild(ta);
        openSheet('编辑隐藏文件', body, [
            { text: '取消', value: null },
            { text: '保存', value: true, kind: 'primary' }
        ]).then(function (ok) {
            if (!ok) return;
            prefs.hidden = ta.value.split('\n').map(function (s) { return s.trim(); }).filter(function (s) { return s.charAt(0) === '/'; });
            setPref('hidden', prefs.hidden);
            render();
        });
    }
    function hideItems(paths) {
        var msg = paths.length === 1 ? '确定要隐藏 ' + baseName(paths[0]) + ' 吗？' : '确定要隐藏这 ' + paths.length + ' 个项目吗？';
        dialog({ title: '隐藏', msg: msg + '\n隐藏后可在“更多 → 编辑隐藏文件”中重新显示。', ok: '隐藏' }).then(function (yes) {
            if (!yes) return;
            paths.forEach(function (p) { if (!isManualHidden(p)) prefs.hidden.push(p); });
            setPref('hidden', prefs.hidden);
            clearSelection();
            render();
        });
    }
    function hiddenMenuItems() {
        return [
            [(prefs.showSystemHidden ? '✓ ' : '') + '显示系统隐藏', function () {
                prefs.showSystemHidden = !prefs.showSystemHidden;
                setPref('show-system-hidden', prefs.showSystemHidden);
                render();
            }],
            [(prefs.showManualHidden ? '✓ ' : '') + '显示手动隐藏', function () {
                prefs.showManualHidden = !prefs.showManualHidden;
                setPref('show-manual-hidden', prefs.showManualHidden);
                render();
            }],
            ['隐藏所选文件', function () { hideItems(selectedPaths()); }, !selectedNames().length],
            ['编辑隐藏文件', editHidden]
        ];
    }
    function anchorMenu(btn, items) {
        var r = btn.getBoundingClientRect();
        openMenu(r.right, r.bottom + 4, items, true);
    }
    el('hiddenbtn').onclick = function (e) { e.stopPropagation(); anchorMenu(this, hiddenMenuItems()); };
    el('sortbtn').onclick = function (e) { e.stopPropagation(); openSort(); };
    el('more').onclick = function (e) {
        e.stopPropagation();
        var items = [
            ['新建标签页', newTab],
            ['后退', function () { backBtn.onclick(); }, !hist.length],
            ['上一级', function () { parentBtn.onclick(); }, !parentPath],
            ['输入路径', editPath],
            ['复制路径', function () { copyText(cur).then(function () { toast('已复制路径 ' + cur); }); }],
            null,
            ['刷新', function () { load(cur, true); }],
            ['排序方式', openSort],
            ['隐藏文件…', function () { setTimeout(function () { anchorMenu(el('more'), hiddenMenuItems()); }, 0); }]
        ];
        // 窄屏没有侧栏：快捷位置收进菜单
        if (window.matchMedia('(max-width: 720px)').matches && config.shortcuts.length) {
            items.push(null);
            config.shortcuts.forEach(function (sc) {
                items.push([(sc.kind === 'file' ? '下载 ' : '前往 ') + sc.label, function () {
                    if (sc.kind === 'file') downloadShortcut(sc); else load(sc.path);
                }]);
            });
        }
        anchorMenu(this, items);
    };
    var heads = document.querySelectorAll('th.sortable');
    for (var h = 0; h < heads.length; h++) {
        heads[h].onclick = function () {
            var by = this.getAttribute('data-sort');
            var spec = sortSpec();
            var next = { by: by, reverse: spec.by === by ? !spec.reverse : false };
            if (prefs.folderSort[cur]) { prefs.folderSort[cur] = next; setPref('folder-sort', prefs.folderSort); }
            else { prefs.sort = next; setPref('sort', next); }
            render();
        };
    }

    var menu = el('menu');
    function openMenu(x, y, items, alignRight) {
        menu.innerHTML = '';
        items.forEach(function (it) {
            if (!it) { menu.appendChild(node('div', 'ctx-sep')); return; }
            var b = node('button', 'ctx-item' + (it[3] ? ' ' + it[3] : ''), it[0]);
            b.type = 'button';
            b.setAttribute('role', 'menuitem');
            if (it[2]) b.disabled = true;
            b.onclick = function (ev) { ev.stopPropagation(); closeMenu(); it[1](); };
            menu.appendChild(b);
        });
        menu.hidden = false;
        var w = menu.offsetWidth, hh = menu.offsetHeight;
        var left = alignRight ? x - w : x;
        left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
        var top = Math.max(8, Math.min(y, window.innerHeight - hh - 8));
        menu.style.left = left + 'px';
        menu.style.top = top + 'px';
        var first = menu.querySelector('button:not(:disabled)');
        if (first) first.focus();
    }
    function closeMenu() { menu.hidden = true; }
    document.addEventListener('click', function (e) {
        if (!menu.hidden && !menu.contains(e.target)) closeMenu();
    });
    menu.addEventListener('keydown', function (e) {
        var items = Array.prototype.slice.call(menu.querySelectorAll('button:not(:disabled)'));
        var i = items.indexOf(document.activeElement);
        if (e.key === 'ArrowDown') { e.preventDefault(); (items[i + 1] || items[0]).focus(); }
        else if (e.key === 'ArrowUp') { e.preventDefault(); (items[i - 1] || items[items.length - 1]).focus(); }
        else if (e.key === 'Escape') { e.preventDefault(); closeMenu(); listWrap.focus(); }
    });

    function entryMenu(e, x, y) {
        var full = join(cur, e.name);
        if (!selected[e.name]) { selected = {}; selected[e.name] = true; updateSelection(); }
        var multi = selectedNames().length > 1;
        var items = [];
        if (!multi) {
            items.push(['打开', function () { openEntry(e); }]);
            if (!e.dir) items.push(['编辑', function () { openEditor(full, e.size); }]);
        }
        items.push(['下载', downloadSelected]);
        items.push(null);
        items.push(['复制', function () { setClip('copy'); }]);
        items.push(['剪切', function () { setClip('cut'); }, anyProtected()]);
        items.push(['粘贴', function () { paste(e.dir && !multi ? full : cur); }, !clip]);
        items.push(null);
        if (!multi) {
            items.push(['重命名', function () { renameEntry(e); }, e.protected]);
            if (!e.dir && /\.zip$/i.test(e.name)) items.push(['解压', function () { extractEntry(e); }, e.protected]);
        }
        items.push(['隐藏', function () { hideItems(selectedPaths()); }]);
        items.push(['删除', deleteSelected, anyProtected(), 'danger-text']);
        if (!multi) {
            items.push(null);
            items.push(['复制路径', function () { copyText(full).then(function () { toast('已复制路径 ' + full); }); }]);
            items.push(['属性', function () { showProperties(full); }]);
        }
        openMenu(x, y, items);
    }

    function selectedNames() { return shown.filter(function (e) { return selected[e.name]; }).map(function (e) { return e.name; }); }
    function selectedPaths() { return selectedNames().map(function (n) { return join(cur, n); }); }
    function selectedEntries() { return shown.filter(function (e) { return selected[e.name]; }); }
    function anyProtected() { return selectedEntries().some(function (e) { return e.protected; }); }
    function clearSelection() { selected = {}; anchor = -1; updateSelection(); }
    function updateSelection() {
        var names = selectedNames();
        var rows = el('list').getElementsByTagName('tr');
        for (var i = 0; i < rows.length; i++) {
            var name = rows[i].getAttribute('data-name');
            if (name == null) continue;
            var on = !!selected[name];
            rows[i].classList.toggle('selected', on);
            rows[i].classList.toggle('cursor', i === cursor);
            var ib = rows[i].querySelector('.file-icon');
            if (ib) ib.setAttribute('aria-pressed', on ? 'true' : 'false');
        }
        // 工具栏：依赖选择的按钮在未选中时置灰禁用（重命名 / 属性只对单个条目）
        var none = names.length === 0, one = names.length === 1, prot = anyProtected();
        el('sel-all').textContent = !none && names.length === shown.length ? '取消全选' : '全选';
        el('sel-all').disabled = !shown.length;
        ['sel-invert', 'sel-type', 'sel-download', 'sel-copy'].forEach(function (id) { el(id).disabled = none; });
        el('sel-cut').disabled = none || prot;
        el('sel-delete').disabled = none || prot;
        el('sel-rename').disabled = !one || prot;
        el('sel-props').disabled = !one;
        el('count').textContent = names.length
            ? '已选 ' + names.length + ' / ' + shown.length + ' 项'
            : shown.length + ' 项' + (entries.length > shown.length ? '（隐藏 ' + (entries.length - shown.length) + '）' : '');
    }
    function toggle(i, shift) {
        var e = shown[i];
        if (!e) return;
        if (shift && anchor >= 0) {
            var a = Math.min(anchor, i), b = Math.max(anchor, i);
            for (var k = a; k <= b; k++) selected[shown[k].name] = true;
        } else {
            if (selected[e.name]) delete selected[e.name];
            else selected[e.name] = true;
            anchor = i;
        }
        cursor = i;
        updateSelection();
    }
    function addCell(tr, text, className, label) {
        var td = document.createElement('td');
        if (className) td.className = className;
        if (label) td.setAttribute('data-label', label);
        td.textContent = text;
        tr.appendChild(td);
        return td;
    }

    function render() {
        var tb = el('list');
        shown = entries.filter(visible).sort(compare(sortSpec()));
        var still = {};
        shown.forEach(function (e) { if (selected[e.name]) still[e.name] = true; });
        selected = still;
        if (cursor >= shown.length) cursor = shown.length - 1;
        tb.innerHTML = '';
        var spec = sortSpec();
        for (var h = 0; h < heads.length; h++) {
            var by = heads[h].getAttribute('data-sort');
            heads[h].classList.toggle('sorted', by === spec.by);
            heads[h].classList.toggle('desc', by === spec.by && spec.reverse);
        }
        shown.forEach(function (e, i) {
            var full = join(cur, e.name);
            var tr = document.createElement('tr');
            tr.className = (e.dir ? 'd' : 'f') + (clip && clip.op === 'cut' && clip.items.indexOf(full) >= 0 ? ' cut-pending' : '');
            tr.setAttribute('data-name', e.name);
            if (isManualHidden(full) || e.name.charAt(0) === '.') tr.className += ' is-hidden';

            // 图标即选择按钮（与参考一致）：点图标切换选中，点名称打开
            var sel = document.createElement('td');
            sel.className = 'sel';
            var ib = node('button', 'file-icon');
            ib.type = 'button';
            ib.setAttribute('data-ext', e.dir ? 'dir' : ext(e.name));
            ib.setAttribute('aria-label', '选择 ' + e.name);
            ib.setAttribute('aria-pressed', 'false');
            ib.onclick = function (ev) { ev.stopPropagation(); toggle(i, ev.shiftKey); };
            sel.appendChild(ib);
            tr.appendChild(sel);

            var td = document.createElement('td');
            td.className = 'n';
            td.setAttribute('translate', 'no');
            var a = document.createElement('a');
            a.appendChild(node('span', 'nm', e.name));
            a.appendChild(node('span', 'mt', fmtT(e.mtime)));
            a.title = e.name;
            a.href = e.dir ? '#' : '/download?path=' + encodeURIComponent(full);
            a.onclick = function (ev) {
                ev.preventDefault();
                if (ev.shiftKey || ev.ctrlKey || ev.metaKey) { toggle(i, ev.shiftKey); return; }
                if (selectedNames().length) { toggle(i, false); return; }
                openEntry(e);
            };
            td.appendChild(a);
            tr.appendChild(td);

            addCell(tr, e.dir ? '--' : sizeMB(e.size || 0), 'r', '大小');

            var op = document.createElement('td');
            op.className = 'ops';
            op.setAttribute('data-label', '操作');
            var more = node('button', 'row-more', '⋮');
            more.type = 'button';
            more.setAttribute('aria-label', e.name + ' 的操作');
            more.onclick = function (ev) {
                ev.stopPropagation();
                var r = more.getBoundingClientRect();
                cursor = i;
                entryMenu(e, r.right - 180, r.bottom);
            };
            op.appendChild(more);
            tr.appendChild(op);

            tr.addEventListener('click', function (ev) {
                // 长按已弹出菜单：吞掉随后的 click，避免同时切换选中 / 打开条目
                if (tr._longPress) { tr._longPress = false; ev.preventDefault(); ev.stopPropagation(); }
            }, true);
            tr.onclick = function (ev) {
                if (ev.target.closest('a,button,input')) return;
                toggle(i, ev.shiftKey);
            };
            tr.oncontextmenu = function (ev) {
                ev.preventDefault();
                cursor = i;
                entryMenu(e, ev.clientX, ev.clientY);
            };
            var pressTimer = null;
            tr.addEventListener('touchstart', function (ev) {
                var t = ev.touches[0];
                pressTimer = setTimeout(function () {
                    pressTimer = null;
                    tr._longPress = true;
                    cursor = i;
                    entryMenu(e, t.clientX, t.clientY);
                }, 550);
            }, { passive: true });
            ['touchend', 'touchmove', 'touchcancel'].forEach(function (n) {
                tr.addEventListener(n, function () { if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; } });
            });
            tb.appendChild(tr);
        });
        if (!shown.length) tb.innerHTML = '<tr><td class="empty" colspan="4">此文件夹为空</td></tr>';
        updateSelection();
    }

    function load(p, nohist) {
        if (busy) return;
        var my = ++seq;
        jfetch('/api/list?path=' + encodeURIComponent(p)).then(function (d) {
            if (my !== seq) return;
            if (!nohist && d.path !== cur) hist.push(cur);
            if (d.path !== cur) { selected = {}; cursor = -1; anchor = -1; }
            cur = d.path;
            parentPath = d.parent;
            entries = Array.isArray(d.entries) ? d.entries : [];
            tabs[activeTab] = cur;
            saveTabs();
            renderTabs();
            backBtn.disabled = hist.length === 0;
            parentBtn.disabled = !parentPath;
            renderBreadcrumb();
            var locations = el('quick').getElementsByTagName('button');
            for (var i = 0; i < locations.length; i++) {
                var root = locations[i].getAttribute('data-path');
                if (locations[i].getAttribute('data-kind') !== 'file') {
                    locations[i].className = cur === root || (root !== '/' && cur.indexOf(root + '/') === 0) ? 'active' : '';
                } else {
                    locations[i].className = '';
                }
                if (locations[i].className === 'active') locations[i].scrollIntoView({ block: 'nearest', inline: 'nearest' });
            }
            render();
        }).catch(function (err) {
            if (my !== seq) return;
            say('列表失败: ' + errText(err));
        });
    }

    backBtn.onclick = function () { if (!busy && hist.length) load(hist.pop(), true); };
    parentBtn.onclick = function () { if (!busy && parentPath) load(parentPath); };
    refreshBtn.onclick = function () { if (!busy) load(cur, true); };
    el('sel-all').onclick = function () {
        if (selectedNames().length === shown.length) { clearSelection(); return; }
        shown.forEach(function (e) { selected[e.name] = true; });
        updateSelection();
    };
    el('sel-invert').onclick = function () {
        var next = {};
        shown.forEach(function (e) { if (!selected[e.name]) next[e.name] = true; });
        selected = next;
        updateSelection();
    };
    el('sel-type').onclick = function () {
        var kinds = {};
        selectedEntries().forEach(function (e) { kinds[e.dir ? '/' : ext(e.name)] = true; });
        shown.forEach(function (e) { if (kinds[e.dir ? '/' : ext(e.name)]) selected[e.name] = true; });
        updateSelection();
    };
    el('sel-copy').onclick = function () { setClip('copy'); };
    el('sel-cut').onclick = function () { setClip('cut'); };
    el('sel-delete').onclick = deleteSelected;
    el('sel-rename').onclick = function () { var l = selectedEntries(); if (l.length === 1) renameEntry(l[0]); };
    el('sel-props').onclick = function () { var l = selectedPaths(); if (l.length === 1) showProperties(l[0]); };
    el('sel-download').onclick = downloadSelected;

    function openEntry(e) {
        var full = join(cur, e.name);
        if (e.dir) { if (!busy) load(full); return; }
        if (IMAGE_EXT.test(e.name) || VIDEO_EXT.test(e.name) || AUDIO_EXT.test(e.name)) { openViewer(e.name); return; }
        if (TEXT_EXT.test(e.name)) { openEditor(full, e.size); return; }
        location.href = '/download?path=' + encodeURIComponent(full);
    }

    function renameEntry(e) {
        var full = join(cur, e.name);
        dialog({ title: '重命名', msg: '输入新的名称（以 / 开头的完整路径表示移动）', input: e.name, ok: '保存' }).then(function (to) {
            if (!to || to === e.name) return;
            var target = to.charAt(0) === '/' ? to : join(cur, to);
            post('/api/rename?' + q({ path: full, to: target })).then(function () {
                load(cur, true);
            }).catch(function (err) {
                dialog({ title: '重命名失败', msg: err.status === 409 ? '已存在同名项' : errText(err), ok: '知道了' });
            });
        });
    }
    function extractEntry(e) {
        var full = join(cur, e.name);
        if (busy) return;
        dialog({ title: '解压 ZIP', msg: '解压 ' + e.name + '？', ok: '解压' }).then(function (yes) {
            if (!yes) return;
            setBusy(true);
            say('正在解压 ' + e.name + '…');
            jfetch('/api/extract?path=' + encodeURIComponent(full), { method: 'POST' }).then(function (result) {
                say('已解压到 ' + result.path);
                setBusy(false);
                load(cur, true);
            }).catch(function (err) {
                say('解压失败: ' + errText(err));
                setBusy(false);
            });
        });
    }
    // ── 通用进度对话框（复用上传进度 #upprog）：删除 / 复制 / 移动 / 打包 ──
    var op = { active: false, cancelled: false, onCancel: null };
    function progOpen(title, onCancel) {
        op.active = true;
        op.cancelled = false;
        op.onCancel = onCancel || null;
        el('pg-title').textContent = title;
        el('pg-sub').textContent = '进行中';
        el('pg-name').textContent = '';
        el('pg-stats').textContent = '0%';
        el('pg-fill').style.width = '0%';
        el('pg-cancel').disabled = false;
        el('upprog').querySelector('.pg-track').classList.remove('indeterminate');
        showOverlay(el('upprog'), true);
    }
    function progStep(name, done, total) {
        var pct = total ? Math.min(100, Math.floor(done * 100 / total)) : 0;
        el('pg-name').textContent = name;
        el('pg-fill').style.width = pct + '%';
        el('pg-stats').textContent = pct + '%';
    }
    function progBusy(name) {
        el('pg-name').textContent = name;
        el('pg-stats').textContent = '';
        el('upprog').querySelector('.pg-track').classList.add('indeterminate');
    }
    function progClose() {
        op.active = false;
        op.onCancel = null;
        el('upprog').querySelector('.pg-track').classList.remove('indeterminate');
        showOverlay(el('upprog'), false);
    }
    // 收尾：关进度框、刷新列表、提示汇总；有失败时列出失败项
    function opSummary(okMsg, partMsg, failures, cancelledLeft) {
        progClose();
        if (!failures.length && !cancelledLeft) { say(okMsg); return; }
        say(partMsg);
        var lines = failures.map(function (f) { return f.name + ': ' + f.err; });
        if (cancelledLeft) lines.push(t('已取消，剩余 %1 项未处理', cancelledLeft));
        dialog({ title: '部分项目未完成', msg: lines.join('\n'), ok: '知道了' });
    }

    function deleteSelected() {
        var paths = selectedPaths();
        if (!paths.length || busy || anyProtected()) return;
        var msg = paths.length === 1 ? '确定要删除 ' + baseName(paths[0]) + ' 吗？' : '确定要删除这 ' + paths.length + ' 个项目吗？';
        dialog({ title: '删除', msg: msg + '目录将递归删除，不可恢复。', ok: '删除', danger: true }).then(function (yes) {
            if (!yes) return;
            setBusy(true);
            var i = 0, failures = [];
            progOpen('正在删除...', function () { op.cancelled = true; el('pg-sub').textContent = '正在取消…'; el('pg-cancel').disabled = true; });
            (function next() {
                if (i >= paths.length || op.cancelled) {
                    var left = paths.length - i;
                    progStep(i ? baseName(paths[i - 1]) : '', i, paths.length);
                    setBusy(false);
                    clearSelection();
                    load(cur, true);
                    opSummary('删除成功', t('删除完成，%1 项失败', failures.length + (op.cancelled ? left : 0)), failures, op.cancelled ? left : 0);
                    return;
                }
                var p = paths[i];
                progStep(baseName(p), i, paths.length);
                post('/api/delete?path=' + encodeURIComponent(p)).catch(function (err) {
                    failures.push({ name: baseName(p), err: errText(err) });
                }).then(function () { i++; progStep(baseName(p), i, paths.length); next(); });
            })();
        });
    }
    mkBtn.onclick = function () {
        if (busy) return;
        var body = node('div');
        var kind = radioGroup('newkind', [['dir', '文件夹'], ['file', '文件']], 'dir');
        body.appendChild(kind);
        var input = document.createElement('input');
        input.type = 'text';
        input.placeholder = '输入文件或文件夹名称';
        input.className = 'sheet-input';
        body.appendChild(input);
        var p = openSheet('新建', body, [
            { text: '取消', value: null },
            { text: '创建', value: true, kind: 'primary' }
        ]);
        input.focus();
        input.onkeydown = function (ev) { if (ev.key === 'Enter') { ev.preventDefault(); el('sheet-btns').lastChild.click(); } };
        p.then(function (ok) {
            var name = input.value.trim();
            if (!ok || !name) return;
            if (/[\/\\]/.test(name) || name === '.' || name === '..') { dialog({ title: '新建失败', msg: '文件名含有特殊符号', ok: '知道了' }); return; }
            var target = join(cur, name);
            var isFile = kind.querySelector('input:checked').value === 'file';
            var req = isFile ? post('/api/write?' + q({ path: target, create: '1' }), '') : post('/api/mkdir?path=' + encodeURIComponent(target));
            req.then(function () { load(cur, true); }).catch(function (err) {
                dialog({ title: '新建失败', msg: err.status === 409 ? (isFile ? '已存在同名文件' : '已存在同名文件夹') : errText(err), ok: '知道了' });
            });
        });
    };
    function showProperties(path) {
        var body = node('dl', 'props');
        body.appendChild(node('dd', 'sheet-note', '统计中…'));
        openSheet('属性', body, [
            { text: '复制路径', value: 'copy' },
            { text: '确定', value: true, kind: 'primary' }
        ]).then(function (v) {
            if (v === 'copy') copyText(path).then(function () { toast('已复制路径 ' + path); });
        });
        jfetch('/api/stat?path=' + encodeURIComponent(path)).then(function (s) {
            body.innerHTML = '';
            var types = { directory: '文件夹', file: '文件', link: '链接' };
            var rows = [
                ['名称', s.name],
                ['位置', dirName(s.path)],
                ['类型', (types[s.type] || s.type) + (s.type === 'file' && ext(s.name) ? '（' + ext(s.name).toUpperCase() + '）' : '')]
            ];
            if (s.target) rows.push(['链接目标', s.target]);
            if (s.size != null) rows.push(['逻辑大小', fmt(s.size) + '（' + s.size + ' 字节）']);
            if (s.blocks != null) rows.push(['实际大小', fmt(s.blocks * 512)]);
            if (s.type === 'directory') {
                rows.push(['文件数', String(s.files) + (s.truncated ? '+' : '')]);
                rows.push(['文件夹数', String(s.dirs) + (s.truncated ? '+' : '')]);
            }
            rows.push(['修改时间', fmtT(s.mtime)]);
            if (s.atime) rows.push(['访问时间', fmtT(s.atime)]);
            if (s.permissions) rows.push(['权限', s.permissions]);
            if (s.uid != null) rows.push(['所有者', String(s.uid)]);
            if (s.gid != null) rows.push(['所属组', String(s.gid)]);
            if (s.protected) rows.push(['保护', '重要路径，不可删除或移动']);
            rows.forEach(function (r) {
                body.appendChild(node('dt', null, r[0]));
                body.appendChild(node('dd', null, r[1]));
            });
        }).catch(function (err) {
            body.innerHTML = '';
            body.appendChild(node('dd', 'sheet-note', '暂无可显示的属性：' + errText(err)));
        });
    }

    function setClip(op) {
        var items = selectedPaths();
        if (!items.length) return;
        clip = { op: op, items: items, from: cur };
        updateClip();
        clearSelection();
        render();
    }
    function updateClip() {
        el('clipfab').hidden = !clip;
        if (clip) el('clipinfo').textContent = (clip.op === 'cut' ? '剪切 ' : '复制 ') + clip.items.length + ' 项';
    }
    el('clipcancel').onclick = function () { clip = null; updateClip(); render(); };
    el('clippaste').onclick = function () { paste(cur); };
    function askConflict(name) {
        var body = node('div');
        body.appendChild(node('p', 'sheet-note', '目标位置已存在“' + name + '”。'));
        var all = checkbox('应用到后续冲突', false);
        body.appendChild(all.label);
        return openSheet('存在同名项', body, [
            { text: '跳过当前项', value: 'skip' },
            { text: '替换', value: 'overwrite', kind: 'danger' },
            { text: '保留两份', value: 'rename', kind: 'primary' }
        ]).then(function (v) { return { choice: v, all: all.input.checked }; });
    }
    function paste(dest) {
        if (!clip || busy) return;
        var mode = clip.op === 'cut' ? 'move' : 'copy';
        if (mode === 'move' && dirName(clip.items[0]) === dest) {
            dialog({ title: '无法粘贴', msg: '不能移动到同一目录', ok: '知道了' });
            return;
        }
        var items = clip.items.slice();
        var sticky = null, i = 0, done = 0, failed = 0;
        var failures = [];
        setBusy(true);
        progOpen(mode === 'move' ? '正在移动...' : '正在复制...', function () { op.cancelled = true; el('pg-sub').textContent = '正在取消…'; el('pg-cancel').disabled = true; });
        function finish(left) {
            left = left || 0;
            setBusy(false);
            if (mode === 'move' && !failures.length && !left) clip = null;
            updateClip();
            load(cur, true);
            failed = failures.length + left;
            opSummary((mode === 'move' ? '移动' : '复制') + '成功（' + done + ' 项）', (mode === 'move' ? '移动' : '复制') + '完成，' + failed + ' 项失败（' + done + ' 项）', failures, left);
        }
        function attempt(src, conflict) {
            if (mode === 'copy' && dirName(src) === dest && !conflict) conflict = 'rename';
            return post('/api/' + mode + '?' + q({ path: src, to: join(dest, baseName(src)), conflict: conflict || 'ask' }));
        }
        (function next() {
            if (op.cancelled) return finish(items.length - i);
            progStep(i ? baseName(items[i - 1]) : '', i, items.length);
            if (i >= items.length) return finish();
            var src = items[i++];
            progStep(baseName(src), i - 1, items.length);
            attempt(src, sticky).then(function () { done++; next(); }).catch(function (err) {
                if (err.status !== 409) {
                    failures.push({ name: baseName(src), err: errText(err) });
                    return next();
                }
                askConflict(baseName(src)).then(function (r) {
                    if (!r.choice) return finish(items.length - i + 1);
                    if (r.all) sticky = r.choice;
                    attempt(src, r.choice).then(function () { done++; next(); }).catch(function (e2) {
                        failures.push({ name: baseName(src), err: errText(e2) });
                        next();
                    });
                });
            });
        })();
    }

    function triggerDownload(url, name) {
        var link = document.createElement('a');
        link.href = url;
        if (name) link.download = name;
        document.body.appendChild(link);
        link.click();
        link.remove();
    }
    function zipDownload(paths) {
        var name = paths.length === 1 ? baseName(paths[0]) + '.zip' : (cur === '/' ? 'root' : baseName(cur)) + '.zip';
        setBusy(true);
        // 打包在设备后台一次完成，没有逐项进度：显示不定进度条；取消即放弃结果（不再下载）
        progOpen('正在打包...', function () { op.cancelled = true; setBusy(false); progClose(); say('已取消打包下载'); });
        progBusy(name);
        post('/api/zip', JSON.stringify({ paths: paths, name: name })).then(function (r) {
            if (op.cancelled) return;
            setBusy(false);
            progStep(name, 1, 1);
            progClose();
            say('打包完成，开始下载 ' + r.name);
            triggerDownload('/api/zip?id=' + encodeURIComponent(r.id), r.name);
        }).catch(function (err) {
            if (op.cancelled) return;
            setBusy(false);
            progClose();
            dialog({ title: '打包下载准备失败', msg: errText(err), ok: '知道了' });
        });
    }
    function downloadSelected() {
        var list = selectedEntries();
        if (!list.length) return;
        var paths = list.map(function (e) { return join(cur, e.name); });
        var hasDir = list.some(function (e) { return e.dir; });
        if (list.length === 1 && !hasDir) { triggerDownload('/download?path=' + encodeURIComponent(paths[0]), list[0].name); return; }
        if (hasDir) {
            openSheet('下载方式', '包含文件夹时只能打包下载。', [
                { text: '取消', value: null },
                { text: '打包下载', value: 'zip', kind: 'primary' }
            ]).then(function (v) { if (v) zipDownload(paths); });
            return;
        }
        openSheet('下载方式', '选择这 ' + list.length + ' 个项目的下载方式', [
            { text: '取消', value: null },
            { text: '直接下载', value: 'direct' },
            { text: '打包下载', value: 'zip', kind: 'primary' }
        ]).then(function (v) {
            if (v === 'zip') zipDownload(paths);
            else if (v === 'direct') paths.forEach(function (p, k) {
                setTimeout(function () { triggerDownload('/download?path=' + encodeURIComponent(p), baseName(p)); }, k * 400);
            });
        });
    }

    function downloadShortcut(s) {
        fetch('/download?path=' + encodeURIComponent(s.path)).then(function (response) {
            if (!response.ok) { var err = new Error('HTTP ' + response.status); err.status = response.status; throw err; }
            return response.blob();
        }).then(function (blob) {
            var url = URL.createObjectURL(blob);
            triggerDownload(url, s.name || s.label);
            setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
        }).catch(function (err) {
            dialog({ title: '日志不可用', msg: err.status === 404 ? (s.missing || '文件尚未生成。') : String(err), ok: '知道了' });
        });
    }
    config.shortcuts.forEach(function (s) {
        var b = document.createElement('button');
        b.type = 'button';
        b.textContent = s.label;
        b.setAttribute('data-path', s.path);
        b.setAttribute('data-kind', s.kind || 'directory');
        b.title = s.path;
        b.onclick = function () {
            if (busy) return;
            if (s.kind === 'file') downloadShortcut(s);
            else load(s.path);
        };
        el('quick').appendChild(b);
    });

    var viewer = el('viewer');
    var media = [], mediaIndex = 0, actualSize = false;
    function openViewer(name) {
        media = shown.filter(function (e) {
            return !e.dir && (IMAGE_EXT.test(e.name) || VIDEO_EXT.test(e.name) || AUDIO_EXT.test(e.name));
        }).map(function (e) { return e.name; });
        mediaIndex = Math.max(0, media.indexOf(name));
        viewer.hidden = false;
        showMedia();
        el('vw-close').focus();
    }
    function showMedia() {
        var name = media[mediaIndex];
        var full = join(cur, name);
        var stage = el('vw-stage');
        stage.innerHTML = '';
        var m;
        if (IMAGE_EXT.test(name)) {
            m = document.createElement('img');
            m.alt = name;
            m.className = actualSize ? 'actual' : 'fit';
            m.onerror = function () { stage.textContent = '预览加载失败'; };
            el('vw-scale').hidden = false;
        } else {
            m = document.createElement(VIDEO_EXT.test(name) ? 'video' : 'audio');
            m.controls = true;
            m.autoplay = true;
            el('vw-scale').hidden = true;
        }
        m.src = '/download?path=' + encodeURIComponent(full) + '&inline=1';
        stage.appendChild(m);
        el('vw-title').textContent = name;
        el('vw-index').textContent = (mediaIndex + 1) + ' / ' + media.length;
        el('vw-dl').href = '/download?path=' + encodeURIComponent(full);
        el('vw-dl').setAttribute('download', name);
        el('vw-scale').textContent = actualSize ? '适应屏幕' : '实际大小';
        el('vw-prev').hidden = el('vw-next').hidden = media.length < 2;
    }
    function stepMedia(d) {
        if (media.length < 2) return;
        mediaIndex = (mediaIndex + d + media.length) % media.length;
        showMedia();
    }
    function closeViewer() { el('vw-stage').innerHTML = ''; viewer.hidden = true; listWrap.focus(); }
    el('vw-close').onclick = closeViewer;
    el('vw-prev').onclick = function () { stepMedia(-1); };
    el('vw-next').onclick = function () { stepMedia(1); };
    el('vw-scale').onclick = function () { actualSize = !actualSize; showMedia(); };

    var editor = el('editor');
    var edText = el('ed-text');
    var ed = { path: null, raw: null, saved: '', eol: 'lf', enc: 'utf-8' };
    function edDirty() { return edText.value !== ed.saved; }
    function edStatus() {
        el('ed-dirty').hidden = !edDirty();
        var v = edText.value, pos = edText.selectionStart;
        var before = v.slice(0, pos);
        el('ed-pos').textContent = '行 ' + before.split('\n').length + '，列 ' + (pos - before.lastIndexOf('\n'));
    }
    function decode(buf, enc) {
        try { return new TextDecoder(enc).decode(buf); } catch (e) { return null; }
    }
    function encLabel(enc) {
        var o = el('ed-enc').querySelector('option[value="' + enc + '"]');
        return o ? o.textContent : enc;
    }
    function edLoadText() {
        var text = decode(ed.raw, ed.enc);
        if (text == null) { el('ed-msg').textContent = '当前浏览器不支持该编码'; return; }
        if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
        ed.eol = /\r\n/.test(text) ? 'crlf' : 'lf';
        text = text.replace(/\r\n/g, '\n');
        edText.value = text;
        ed.saved = text;
        el('ed-eol').value = ed.eol;
        edStatus();
    }
    function openEditor(path, size) {
        if (size > EDIT_LIMIT) {
            dialog({ title: '文件过大', msg: '文本编辑器最多打开 ' + fmt(EDIT_LIMIT) + ' 的文件。', ok: '知道了' });
            return;
        }
        fetch('/download?path=' + encodeURIComponent(path) + '&inline=1').then(function (r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            return r.arrayBuffer();
        }).then(function (buf) {
            ed.path = path;
            ed.raw = buf;
            ed.enc = 'utf-8';
            el('ed-enc').value = 'utf-8';
            el('ed-title').textContent = baseName(path);
            el('ed-title').title = path;
            el('ed-msg').textContent = '';
            edLoadText();
            editor.hidden = false;
            edText.focus();
            edText.setSelectionRange(0, 0);
            edText.scrollTop = 0;
        }).catch(function (err) {
            dialog({ title: '打开失败', msg: errText(err), ok: '知道了' });
        });
    }
    function closeEditor() {
        var go = edDirty()
            ? dialog({ title: '未保存的修改', msg: '关闭后未保存的修改会丢失，确定关闭吗？', ok: '丢弃修改', danger: true })
            : Promise.resolve(true);
        go.then(function (yes) {
            if (!yes) return;
            editor.hidden = true;
            el('ed-search').hidden = true;
            ed.path = null;
            listWrap.focus();
        });
    }
    function saveEditor() {
        var text = edText.value;
        if (ed.eol === 'crlf') text = text.replace(/\n/g, '\r\n');
        el('ed-msg').textContent = '保存中…';
        post('/api/write?' + q({ path: ed.path }), text).then(function () {
            ed.saved = edText.value;
            ed.enc = 'utf-8';
            el('ed-enc').value = 'utf-8';
            el('ed-msg').textContent = '已保存（UTF-8，' + ed.eol.toUpperCase() + '）';
            edStatus();
            load(cur, true);
        }).catch(function (err) {
            el('ed-msg').textContent = '保存失败：' + errText(err);
        });
    }
    el('ed-close').onclick = closeEditor;
    el('ed-save').onclick = saveEditor;
    el('ed-undo').onclick = function () { edText.focus(); document.execCommand('undo'); edStatus(); };
    el('ed-redo').onclick = function () { edText.focus(); document.execCommand('redo'); edStatus(); };
    el('ed-eol').onchange = function () { ed.eol = this.value; el('ed-msg').textContent = '保存时使用 ' + ed.eol.toUpperCase() + ' 换行'; };
    el('ed-enc').onchange = function () {
        var enc = this.value;
        function apply() { ed.enc = enc; edLoadText(); el('ed-msg').textContent = '以 ' + encLabel(enc) + ' 重新解码；保存统一为 UTF-8'; }
        if (edDirty()) {
            dialog({ title: '切换编码', msg: '重新解码会丢弃未保存的修改。', ok: '继续', danger: true }).then(function (yes) {
                if (yes) apply(); else el('ed-enc').value = ed.enc;
            });
        } else apply();
    };
    edText.addEventListener('input', edStatus);
    edText.addEventListener('keyup', edStatus);
    edText.addEventListener('click', edStatus);
    edText.addEventListener('keydown', function (e) {
        if (e.key === 'Tab' && !e.ctrlKey && !e.metaKey) { e.preventDefault(); document.execCommand('insertText', false, '    '); }
    });
    function scrollToLine(line) {
        var lh = parseFloat(getComputedStyle(edText).lineHeight) || 20;
        edText.scrollTop = Math.max(0, (line - 5) * lh);
    }
    el('ed-pos').onclick = function () {
        dialog({ title: '跳转位置', msg: '输入行号（可用 行:列）', input: '', ok: '跳转' }).then(function (v) {
            if (!v) return;
            var m = /^(\d+)(?::(\d+))?$/.exec(v.trim());
            if (!m) return;
            var lines = edText.value.split('\n');
            var line = Math.max(1, Math.min(lines.length, +m[1]));
            var pos = 0;
            for (var k = 0; k < line - 1; k++) pos += lines[k].length + 1;
            pos += Math.min(lines[line - 1].length, Math.max(0, (+m[2] || 1) - 1));
            edText.focus();
            edText.setSelectionRange(pos, pos);
            scrollToLine(line);
            edStatus();
        });
    };
    function edRegex() {
        var qv = el('ed-q').value;
        if (!qv) return null;
        var src = el('ed-regex').checked ? qv : qv.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        if (el('ed-word').checked) src = '\\b' + src + '\\b';
        try { return new RegExp(src, 'gm' + (el('ed-case').checked ? '' : 'i')); }
        catch (e) { el('ed-count').textContent = '正则表达式无效'; return null; }
    }
    function edMatches() {
        var re = edRegex();
        if (!re) return [];
        var out = [], m, v = edText.value;
        while ((m = re.exec(v)) && out.length < 100000) {
            if (m[0] === '') { re.lastIndex++; continue; }
            out.push([m.index, m.index + m[0].length]);
        }
        return out;
    }
    function edFind(dir) {
        var list = edMatches();
        if (!list.length) { if (el('ed-q').value) el('ed-count').textContent = '找不到文本'; return; }
        var idx = -1, k;
        if (dir > 0) {
            for (k = 0; k < list.length; k++) if (list[k][0] >= edText.selectionEnd) { idx = k; break; }
            if (idx < 0) idx = 0;
        } else {
            for (k = list.length - 1; k >= 0; k--) if (list[k][0] < edText.selectionStart) { idx = k; break; }
            if (idx < 0) idx = list.length - 1;
        }
        edText.focus();
        edText.setSelectionRange(list[idx][0], list[idx][1]);
        scrollToLine(edText.value.slice(0, list[idx][0]).split('\n').length);
        el('ed-count').textContent = (idx + 1) + ' / ' + list.length;
        edStatus();
    }
    function edReplaceOne() {
        var re = edRegex();
        if (!re) return;
        var sel = edText.value.slice(edText.selectionStart, edText.selectionEnd);
        var one = new RegExp('^(?:' + re.source + ')$', re.flags.replace('g', ''));
        if (sel && one.test(sel)) {
            var rep = el('ed-regex').checked ? sel.replace(one, el('ed-r').value) : el('ed-r').value;
            document.execCommand('insertText', false, rep);
        }
        edFind(1);
    }
    function edReplaceAll() {
        var list = edMatches();
        if (!list.length) { el('ed-count').textContent = '找不到文本'; return; }
        var re = edRegex();
        var rv = el('ed-r').value;
        var next = edText.value.replace(re, el('ed-regex').checked ? rv : function () { return rv; });
        edText.focus();
        edText.select();
        document.execCommand('insertText', false, next);
        el('ed-count').textContent = '已替换 ' + list.length + ' 处';
        edStatus();
    }
    el('ed-find').onclick = function () {
        var box = el('ed-search');
        box.hidden = !box.hidden;
        if (!box.hidden) {
            var sel = edText.value.slice(edText.selectionStart, edText.selectionEnd);
            if (sel && sel.indexOf('\n') < 0) el('ed-q').value = sel;
            el('ed-q').focus();
            el('ed-q').select();
        }
    };
    el('ed-next').onclick = function () { edFind(1); };
    el('ed-prev').onclick = function () { edFind(-1); };
    el('ed-rep').onclick = edReplaceOne;
    el('ed-repall').onclick = edReplaceAll;
    el('ed-q').onkeydown = function (e) {
        if (e.key === 'Enter') { e.preventDefault(); edFind(e.shiftKey ? -1 : 1); }
        else if (e.key === 'Escape') { e.preventDefault(); el('ed-search').hidden = true; edText.focus(); }
    };
    el('ed-q').oninput = function () {
        var n = edMatches().length;
        el('ed-count').textContent = el('ed-q').value ? (n ? '共 ' + n + ' 个' : '找不到文本') : '';
    };

    // ── 上传：选择 / 拖入 → 上传对话框（列表：名称 + 大小）→ 开始上传 → 进度对话框（逐个文件、百分比、已传/总量、速度）──
    var upDialog = el('uploads');
    var upProg = el('upprog');
    var queue = [];
    var queueDirs = [];
    var uploading = false;
    var upSticky = null;
    var upCancelled = false;
    function showOverlay(o, on) { o.hidden = !on; o.classList.toggle('on', on); }
    function sizeMB(n) {
        if (n >= 1073741824) return (n / 1073741824).toFixed(1) + ' GB';
        if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
        if (n >= 1024) return (n / 1024).toFixed(1) + ' KB';
        return n + ' B';
    }
    function sizeShort(n) {
        if (n >= 1073741824) return (n / 1073741824).toFixed(2) + 'G';
        if (n >= 1048576) return (n / 1048576).toFixed(2) + 'M';
        if (n >= 1024) return (n / 1024).toFixed(2) + 'K';
        return n + 'B';
    }
    function openUploads() { showOverlay(upDialog, true); renderQueue(); }
    function renderQueue() {
        var list = el('up-list');
        list.innerHTML = '';
        if (!queue.length) list.appendChild(node('div', 'up-empty', '将文件或文件夹拖到这里'));
        queue.forEach(function (it, k) {
            var row = node('div', 'up-row ' + it.state);
            var un = node('span', 'up-name', it.label);
            un.setAttribute('translate', 'no');
            row.appendChild(un);
            var stateText = { done: '已上传', error: '失败：' + (it.err || ''), skip: '已跳过', cancel: '已取消' }[it.state];
            if (stateText) row.appendChild(node('span', 'up-state', stateText));
            row.appendChild(node('span', 'up-size', sizeMB(it.file.size)));
            if (!uploading && (it.state === 'error' || it.state === 'cancel')) {
                var retry = node('button', 'up-act', '重试');
                retry.type = 'button';
                retry.onclick = function () { it.state = 'wait'; it.err = null; renderQueue(); };
                row.appendChild(retry);
            }
            if (!uploading && it.state !== 'done') {
                var rm = node('button', 'up-act up-remove', '×');
                rm.type = 'button';
                rm.setAttribute('aria-label', '移除 ' + it.label);
                rm.onclick = function () { queue.splice(k, 1); renderQueue(); };
                row.appendChild(rm);
            }
            list.appendChild(row);
        });
        el('up-title').textContent = '上传到 ' + cur;
        el('up-start').disabled = uploading || !queue.some(function (it) { return it.state === 'wait'; });
        el('up-clear').disabled = uploading || !queue.length;
    }
    function enqueue(items, dirs) {
        items.forEach(function (it) { it.state = 'wait'; queue.push(it); });
        (dirs || []).forEach(function (d) { if (queueDirs.indexOf(d) < 0) queueDirs.push(d); });
        openUploads();
    }
    var prog = { name: '', loaded: 0, total: 0, speed: 0, t0: 0, l0: 0 };
    function renderProgress() {
        el('pg-name').textContent = prog.name;
        var pct = prog.total ? Math.min(100, Math.floor(prog.loaded * 100 / prog.total)) : 0;
        el('pg-fill').style.width = pct + '%';
        el('pg-stats').textContent = pct + '%\u2003' + sizeShort(prog.loaded) + '/' + sizeShort(prog.total)
            + (prog.speed ? '\u2003' + sizeMB(prog.speed) + '/s' : '');
    }
    function uploadXhr(it, conflict) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            it.xhr = xhr;
            prog.name = it.label;
            prog.loaded = 0;
            prog.total = it.file.size;
            prog.speed = 0;
            prog.t0 = Date.now();
            prog.l0 = 0;
            renderProgress();
            xhr.open('PUT', '/upload?' + q({ dir: it.dir, name: it.name, conflict: conflict || 'overwrite' }));
            xhr.upload.onprogress = function (e) {
                if (!e.lengthComputable) return;
                var now = Date.now();
                // 速度：约每 0.5 秒取一次增量，指数平滑，避免跳动
                if (now - prog.t0 >= 500) {
                    var inst = (e.loaded - prog.l0) * 1000 / (now - prog.t0);
                    prog.speed = prog.speed ? prog.speed * 0.6 + inst * 0.4 : inst;
                    prog.t0 = now;
                    prog.l0 = e.loaded;
                }
                prog.loaded = e.loaded;
                prog.total = e.total;
                renderProgress();
            };
            xhr.onload = function () {
                it.xhr = null;
                if (xhr.status >= 200 && xhr.status < 300) {
                    prog.loaded = prog.total;
                    renderProgress();
                    return resolve();
                }
                var msg = 'HTTP ' + xhr.status;
                try { msg = JSON.parse(xhr.responseText).error || msg; } catch (e) {}
                var err = new Error(msg);
                err.status = xhr.status;
                reject(err);
            };
            xhr.onerror = function () { it.xhr = null; reject(new Error('网络错误')); };
            xhr.onabort = function () { it.xhr = null; var e = new Error('已取消'); e.cancelled = true; reject(e); };
            xhr.send(it.file);
        });
    }
    function createDirs(dirs) {
        return dirs.reduce(function (p, path) {
            return p.then(function () {
                return post('/api/mkdir?path=' + encodeURIComponent(path)).catch(function (err) { if (err.status !== 409) throw err; });
            });
        }, Promise.resolve());
    }
    function finishUploads() {
        uploading = false;
        setBusy(false);
        showOverlay(upProg, false);
        var left = queue.filter(function (it) { return it.state !== 'done' && it.state !== 'skip'; });
        load(cur, true);
        if (!left.length) {
            say('上传完成');
            queue = [];
            showOverlay(upDialog, false);
        } else {
            say('上传结束，' + left.length + ' 项未完成');
            renderQueue();
        }
    }
    function startUploads() {
        if (uploading) return;
        uploading = true;
        upSticky = null;
        upCancelled = false;
        setBusy(true);
        renderQueue();
        el('pg-title').textContent = '正在上传...';
        el('pg-cancel').disabled = false;
        el('pg-sub').textContent = '进行中';
        prog.name = '';
        prog.loaded = prog.total = prog.speed = 0;
        renderProgress();
        showOverlay(upProg, true);
        var dirs = queueDirs;
        queueDirs = [];
        createDirs(dirs).then(function () {
            (function next() {
                var it = upCancelled ? null : queue.filter(function (x) { return x.state === 'wait'; })[0];
                if (!it) return finishUploads();
                it.state = 'run';
                it.skipped = false;
                var waiting = queue.filter(function (x) { return x.state === 'wait'; }).length;
                el('pg-sub').textContent = '进行中';
                uploadXhr(it, upSticky).catch(function (err) {
                    if (err.status !== 409) throw err;
                    return askConflict(it.label).then(function (r) {
                        if (!r.choice) { var e = new Error('已取消'); e.cancelled = true; throw e; }
                        if (r.all) upSticky = r.choice;
                        if (r.choice === 'skip') { it.skipped = true; return; }
                        return uploadXhr(it, r.choice);
                    });
                }).then(function () {
                    it.state = it.skipped ? 'skip' : 'done';
                }).catch(function (err) {
                    it.state = err.cancelled ? 'cancel' : 'error';
                    it.err = errText(err);
                    if (err.cancelled) upCancelled = true;
                }).then(next);
            })();
        }).catch(function (err) {
            say('创建目录失败: ' + errText(err));
            finishUploads();
        });
    }
    el('up-start').onclick = startUploads;
    el('pg-cancel').onclick = function () {
        if (op.active && op.onCancel) { op.onCancel(); return; }
        upCancelled = true;
        el('pg-sub').textContent = '正在取消…';
        queue.forEach(function (it) { if (it.xhr) it.xhr.abort(); });
    };
    el('up-clear').onclick = function () { if (!uploading) { queue = []; queueDirs = []; renderQueue(); } };
    el('up-close').onclick = function () {
        if (uploading) return;
        showOverlay(upDialog, false);
        queue = queue.filter(function (it) { return it.state === 'wait' || it.state === 'error' || it.state === 'cancel'; });
    };
    upDialog.addEventListener('click', function (e) { if (e.target === upDialog) el('up-close').click(); });
    el('up-addfile').onclick = function () { fileInput.click(); };
    el('up-addmenu').onclick = function (e) {
        e.stopPropagation();
        var r = this.getBoundingClientRect();
        openMenu(r.left, r.bottom + 4, [
            ['添加文件', function () { fileInput.click(); }],
            ['添加文件夹', function () { folderInput.click(); }]
        ]);
    };
    pickFileBtn.onclick = function () { if (!busy) openUploads(); };
    pickFolderBtn.onclick = function () { if (!busy) folderInput.click(); };
    fileInput.onchange = function () {
        var fs = fileInput.files;
        if (!fs.length) return;
        var items = [];
        for (var i = 0; i < fs.length; i++) items.push({ file: fs[i], dir: cur, name: fs[i].name, label: fs[i].name });
        fileInput.value = '';
        enqueue(items, []);
    };
    function cleanJoin(base, parts) {
        var p = base;
        for (var j = 0; j < parts.length; j++) if (parts[j] && parts[j] !== '.' && parts[j] !== '..') p = join(p, parts[j]);
        return p;
    }
    function folderRecords(records, explicitDirs) {
        var items = [], seen = {}, dirs = [];
        function addDir(rel) {
            var parts = rel.split('/'), parent = cur;
            for (var j = 0; j < parts.length; j++) {
                if (!parts[j] || parts[j] === '.' || parts[j] === '..') continue;
                parent = join(parent, parts[j]);
                if (!seen[parent]) { seen[parent] = true; dirs.push(parent); }
            }
        }
        explicitDirs.forEach(addDir);
        records.forEach(function (r) {
            var rel = r.relative || r.file.name;
            var parts = rel.split('/');
            var name = parts.pop();
            addDir(parts.join('/'));
            items.push({ file: r.file, dir: cleanJoin(cur, parts), name: name, label: rel });
        });
        enqueue(items, dirs);
    }
    folderInput.onchange = function () {
        var fs = folderInput.files;
        if (!fs.length) return;
        var records = [];
        for (var i = 0; i < fs.length; i++) records.push({ file: fs[i], relative: fs[i].webkitRelativePath || fs[i].name });
        folderInput.value = '';
        folderRecords(records, []);
    };
    function scanEntry(entry, parent, records, dirs) {
        var relative = parent ? parent + '/' + entry.name : entry.name;
        if (entry.isFile) {
            return new Promise(function (resolve, reject) {
                entry.file(function (file) { records.push({ file: file, relative: relative }); resolve(); }, reject);
            });
        }
        if (!entry.isDirectory) return Promise.resolve();
        dirs.push(relative);
        var reader = entry.createReader();
        return new Promise(function (resolve, reject) {
            function readBatch() {
                reader.readEntries(function (list) {
                    if (!list.length) { resolve(); return; }
                    Promise.all(list.map(function (child) { return scanEntry(child, relative, records, dirs); })).then(readBatch, reject);
                }, reject);
            }
            readBatch();
        });
    }
    var dragDepth = 0;
    function dropTarget(target) {
        target.addEventListener('dragenter', function (event) {
            event.preventDefault();
            if (uploading) return;
            dragDepth++;
            if (target === explorerContent) dropzone.hidden = false;
            else target.classList.add('drag');
        });
        target.addEventListener('dragover', function (event) {
            event.preventDefault();
            if (event.dataTransfer) event.dataTransfer.dropEffect = uploading ? 'none' : 'copy';
        });
        target.addEventListener('dragleave', function () {
            dragDepth = Math.max(0, dragDepth - 1);
            if (dragDepth === 0) { dropzone.hidden = true; target.classList.remove('drag'); }
        });
        target.addEventListener('drop', function (event) {
            event.preventDefault();
            dragDepth = 0;
            dropzone.hidden = true;
            target.classList.remove('drag');
            if (uploading) return;
            var transfer = event.dataTransfer;
            var records = [], dirs = [], scans = [];
            if (transfer.items) {
                for (var i = 0; i < transfer.items.length; i++) {
                    var item = transfer.items[i];
                    var getter = item.webkitGetAsEntry || item.getAsEntry;
                    var entry = getter && getter.call(item);
                    if (entry) scans.push(scanEntry(entry, '', records, dirs));
                }
            }
            if (scans.length) {
                say('正在扫描拖入的内容…');
                Promise.all(scans).then(function () { folderRecords(records, dirs); }).catch(function (err) { say('读取拖入内容失败: ' + err); });
                return;
            }
            var files = transfer.files;
            if (!files || !files.length) return;
            var items = [];
            for (var j = 0; j < files.length; j++) items.push({ file: files[j], dir: cur, name: files[j].name, label: files[j].name });
            enqueue(items, []);
        });
    }
    dropTarget(explorerContent);
    dropTarget(el('up-list'));

    function focusRow(i) {
        if (!shown.length) return;
        cursor = Math.max(0, Math.min(shown.length - 1, i));
        updateSelection();
        var row = el('list').getElementsByTagName('tr')[cursor];
        if (row) row.scrollIntoView({ block: 'nearest' });
    }
    document.addEventListener('keydown', function (e) {
        var mod = e.ctrlKey || e.metaKey;
        var key = (e.key || '').toLowerCase();
        if (!editor.hidden) {
            if (!el('ov').hidden) return;
            if (mod && key === 's') { e.preventDefault(); saveEditor(); }
            else if (mod && key === 'f') { e.preventDefault(); el('ed-find').click(); }
            else if (mod && key === 'g') { e.preventDefault(); el('ed-pos').click(); }
            else if (e.key === 'Escape' && e.target === edText) { e.preventDefault(); closeEditor(); }
            return;
        }
        if (!viewer.hidden) {
            if (e.key === 'Escape') { e.preventDefault(); closeViewer(); }
            else if (e.key === 'ArrowLeft') { e.preventDefault(); stepMedia(-1); }
            else if (e.key === 'ArrowRight') { e.preventDefault(); stepMedia(1); }
            return;
        }
        if (!el('ov').hidden || !sheet.hidden || !menu.hidden) return;
        if (!upDialog.hidden || !upProg.hidden) { if (e.key === 'Escape' && upProg.hidden) el('up-close').click(); return; }
        var tag = (e.target.tagName || '').toLowerCase();
        if (tag === 'input' || tag === 'textarea' || tag === 'select') return;
        var page = Math.max(1, Math.floor(listWrap.clientHeight / 56) - 1);
        switch (e.key) {
        case 'ArrowDown': e.preventDefault(); focusRow(cursor + 1); break;
        case 'ArrowUp': e.preventDefault(); focusRow(cursor - 1); break;
        case 'Home': e.preventDefault(); focusRow(0); break;
        case 'End': e.preventDefault(); focusRow(shown.length - 1); break;
        case 'PageDown': e.preventDefault(); focusRow(cursor + page); break;
        case 'PageUp': e.preventDefault(); focusRow(cursor - page); break;
        case ' ': if (cursor >= 0) { e.preventDefault(); toggle(cursor, e.shiftKey); } break;
        case 'Enter': if (cursor >= 0 && shown[cursor]) { e.preventDefault(); openEntry(shown[cursor]); } break;
        case 'Escape': if (selectedNames().length) { e.preventDefault(); clearSelection(); } else if (clip) { clip = null; updateClip(); render(); } break;
        case 'Delete': if (selectedNames().length) { e.preventDefault(); deleteSelected(); } break;
        case 'Backspace': e.preventDefault(); parentBtn.click(); break;
        case 'F2': if (cursor >= 0 && shown[cursor] && !shown[cursor].protected) { e.preventDefault(); renameEntry(shown[cursor]); } break;
        default:
            if (mod && key === 'a') { e.preventDefault(); el('sel-all').click(); }
            else if (mod && key === 'c' && selectedNames().length) { e.preventDefault(); setClip('copy'); }
            else if (mod && key === 'x' && selectedNames().length && !anyProtected()) { e.preventDefault(); setClip('cut'); }
            else if (mod && key === 'v' && clip) { e.preventDefault(); paste(cur); }
        }
    });
    window.addEventListener('beforeunload', function (e) {
        if ((!editor.hidden && edDirty()) || uploading) { e.preventDefault(); e.returnValue = ''; }
    });

    renderTabs();
    updateClip();
    load(cur, true);
}).catch(function (err) {
    el('path').textContent = '配置加载失败: ' + err;
});
