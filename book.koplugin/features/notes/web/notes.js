(function () {
    var bookPage = 1;
    var bookPages = 1;
    var itemPage = 1;
    var itemPages = 1;
    var currentBook = null;
    var editingKey = null;
    var selected = {};
    var timer = null;

    function toast(msg) {
        var box = el('toasts');
        if (!box) return;
        var n = document.createElement('div');
        n.className = 'sub-toast';
        n.textContent = msg;
        box.appendChild(n);
        setTimeout(function () { n.remove(); }, 2800);
    }

    function bookId(b) {
        return (b.source_id || '') + '\0' + (b.stable_id || '');
    }

    var pageKeys = [];
    var HL_COLORS = {
        red: "#FF3300",
        orange: "#FF8800",
        yellow: "#FFFF33",
        green: "#00AA66",
        olive: "#88FF77",
        cyan: "#00FFEE",
        blue: "#0066FF",
        purple: "#EE00FF",
        pink: "#EE00FF",
        gray: "#8a8f98",
        lightgray: "#8a8f98"
    };
    var HL_DRAWERS = { lighten: true, underscore: true, strikeout: true, invert: true };

    function paintQuote(node, item) {
        var color = String((item && item.color) || "gray").toLowerCase();
        var drawer = String((item && item.drawer) || "lighten").toLowerCase();
        if (!HL_DRAWERS[drawer]) drawer = "lighten";
        var hex = HL_COLORS[color];
        if (!hex && color.charAt(0) === "#") hex = color;
        if (!hex) { color = "gray"; hex = HL_COLORS.gray; }
        if (color === "lightgray") color = "gray";
        node.className = "notes-quote notes-hl notes-hl--" + drawer;
        node.style.setProperty("--hl", hex);
        node.dataset.color = color;
        node.textContent = (item && item.text) || "";
    }

    function queryParts(page) {
        var q = (el('q').value || '').trim();
        var typ = el('type').value || '';
        var parts = ['page=' + page];
        if (q) parts.push('q=' + encodeURIComponent(q));
        if (typ) parts.push('type=' + encodeURIComponent(typ));
        return parts;
    }

    function selectedOnPage() {
        var n = 0;
        for (var i = 0; i < pageKeys.length; i++) {
            if (selected[pageKeys[i]]) n += 1;
        }
        return n;
    }

    function syncBatch() {
        var keys = Object.keys(selected);
        el('batch').hidden = keys.length === 0;
        el('batch-count').textContent = keys.length ? t('已选 %1 条', keys.length) : '';
        var wrap = el('sel-all-wrap');
        var box = el('sel-all');
        if (!wrap || !box) return;
        wrap.hidden = pageKeys.length === 0;
        var n = selectedOnPage();
        box.checked = pageKeys.length > 0 && n === pageKeys.length;
        box.indeterminate = n > 0 && n < pageKeys.length;
    }

    function toggleSelectAll() {
        var box = el('sel-all');
        var allOn = pageKeys.length > 0 && selectedOnPage() === pageKeys.length;
        if (allOn) {
            pageKeys.forEach(function (k) { delete selected[k]; });
        } else {
            pageKeys.forEach(function (k) { selected[k] = true; });
        }
        if (box) {
            box.checked = !allOn;
            box.indeterminate = false;
        }
        var chks = el('list').querySelectorAll('input[type=checkbox]');
        for (var i = 0; i < chks.length; i++) chks[i].checked = !allOn;
        syncBatch();
    }

    function renderBooks(data) {
        var box = el('books');
        box.innerHTML = '';
        var books = data.books || [];
        bookPages = data.pages || 1;
        bookPage = data.page || 1;
        el('book-status').textContent = data.total
            ? t('共 %1 本', data.total) : t('没有符合条件的书籍。');
        el('book-pager').hidden = bookPages <= 1;
        el('book-page-label').textContent = bookPage + ' / ' + bookPages;
        el('book-prev').disabled = bookPage <= 1;
        el('book-next').disabled = bookPage >= bookPages;
        if (!books.length) {
            var empty = document.createElement('div');
            empty.className = 'notes-empty';
            empty.textContent = t('没有符合条件的书籍。');
            box.appendChild(empty);
            currentBook = null;
            return;
        }
        var curId = currentBook ? bookId(currentBook) : '';
        var stillHere = false;
        books.forEach(function (b) {
            if (bookId(b) === curId) stillHere = true;
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.className = bookId(b) === curId ? 'active' : '';
            btn.dataset.id = bookId(b);
            var text = document.createElement('span');
            text.className = 'b-text';
            var title = document.createElement('span');
            title.className = 'b-title';
            title.textContent = b.title || b.stable_id;
            text.appendChild(title);
            if (b.authors) {
                var sub = document.createElement('span');
                sub.className = 'b-sub';
                sub.textContent = b.authors;
                text.appendChild(sub);
            }
            btn.appendChild(text);
            var count = document.createElement('span');
            count.className = 'b-count';
            count.textContent = String(b.count || 0);
            btn.appendChild(count);
            btn.addEventListener('click', function () { selectBook(b); });
            box.appendChild(btn);
        });
        if (stillHere) {
            books.forEach(function (b) { if (bookId(b) === curId) currentBook = b; });
        } else {
            currentBook = books[0];
            itemPage = 1;
            selected = {};
        }
    }

    function selectBook(b) {
        if (currentBook && bookId(currentBook) === bookId(b) && itemPage === 1) {
            currentBook = b;
            highlightBook();
            return loadItems();
        }
        currentBook = b;
        itemPage = 1;
        selected = {};
        highlightBook();
        syncBatch();
        return loadItems();
    }

    function highlightBook() {
        var cur = currentBook ? bookId(currentBook) : '';
        var buttons = el('books').querySelectorAll('button');
        for (var i = 0; i < buttons.length; i++) {
            buttons[i].classList.toggle('active', buttons[i].dataset.id === cur);
        }
        el('list-title').textContent = currentBook
            ? (currentBook.title || currentBook.stable_id) : t('高亮与笔记');
    }

    function renderItems(data) {
        var list = el('list');
        list.innerHTML = '';
        var items = data.items || [];
        pageKeys = items.map(function (it) { return it.key; });
        itemPages = data.pages || 1;
        itemPage = data.page || 1;
        el('status').textContent = currentBook
            ? (data.total ? t('共 %1 条', data.total) : t('没有符合条件的高亮或笔记。'))
            : t('请选择左侧的书。');
        el('item-pager').hidden = itemPages <= 1;
        el('item-page-label').textContent = itemPage + ' / ' + itemPages;
        el('item-prev').disabled = itemPage <= 1;
        el('item-next').disabled = itemPage >= itemPages;
        if (!items.length) {
            var empty = document.createElement('div');
            empty.className = 'notes-empty';
            var strong = document.createElement('strong');
            strong.textContent = t('没有符合条件的高亮或笔记。');
            empty.appendChild(strong);
            list.appendChild(empty);
            pageKeys = [];
            syncBatch();
            return;
        }
        items.forEach(function (item) {
            var row = document.createElement('article');
            row.className = 'notes-row' + (item.key === editingKey ? ' is-open' : '');
            row.dataset.key = item.key;
            var chk = document.createElement('input');
            chk.type = 'checkbox';
            chk.checked = !!selected[item.key];
            chk.setAttribute('aria-label', t('选择'));
            chk.addEventListener('click', function (ev) {
                ev.stopPropagation();
                if (chk.checked) selected[item.key] = true; else delete selected[item.key];
                syncBatch();
            });
            var body = document.createElement('div');
            body.className = 'notes-body';
            var cite = document.createElement('p');
            cite.className = 'notes-cite';
            var quote = document.createElement('span');
            paintQuote(quote, item);
            cite.appendChild(quote);
            body.appendChild(cite);
            var meta = document.createElement('p');
            meta.className = 'notes-meta';
            var bits = [];
            if (item.note) bits.push(item.note);
            if (item.chapter) bits.push(item.chapter);
            if (item.datetime) bits.push(item.datetime);
            meta.textContent = bits.join(' · ');
            if (bits.length) body.appendChild(meta);
            var ops = document.createElement('div');
            ops.className = 'notes-ops';
            var editBtn = document.createElement('button');
            editBtn.type = 'button';
            editBtn.className = 'file-action';
            editBtn.textContent = t('编辑');
            editBtn.addEventListener('click', function (ev) {
                ev.stopPropagation();
                openEdit(item.key);
            });
            var delBtn = document.createElement('button');
            delBtn.type = 'button';
            delBtn.className = 'file-action danger-text';
            delBtn.textContent = t('删除');
            delBtn.addEventListener('click', function (ev) {
                ev.stopPropagation();
                confirmDelete([item.key]);
            });
            ops.appendChild(editBtn);
            ops.appendChild(delBtn);
            row.appendChild(chk);
            row.appendChild(body);
            row.appendChild(ops);
            row.addEventListener('click', function (ev) {
                if (ev.target === chk) return;
                openEdit(item.key);
            });
            list.appendChild(row);
        });
        syncBatch();
    }

    function loadBooks() {
        return jfetch('/api/notes/books?' + queryParts(bookPage).join('&')).then(function (data) {
            renderBooks(data);
            highlightBook();
        }).catch(function (err) {
            el('book-status').textContent = t('加载失败：%1', err.message || err);
        });
    }

    function loadItems() {
        if (!currentBook) {
            renderItems({ items: [], total: 0, page: 1, pages: 1 });
            return Promise.resolve();
        }
        var parts = queryParts(itemPage);
        parts.push('source_id=' + encodeURIComponent(currentBook.source_id || ''));
        parts.push('stable_id=' + encodeURIComponent(currentBook.stable_id || ''));
        return jfetch('/api/notes/list?' + parts.join('&')).then(function (data) {
            renderItems(data);
        }).catch(function (err) {
            el('status').textContent = t('加载失败：%1', err.message || err);
        });
    }

    function reloadAll() {
        return loadBooks().then(loadItems).then(syncBatch);
    }

    function setEditOpen(on) {
        var ov = el('edit-ov');
        ov.hidden = !on;
        ov.className = on ? 'overlay on' : 'overlay';
        if (!on) {
            editingKey = null;
            var rows = document.querySelectorAll('.notes-row.is-open');
            for (var i = 0; i < rows.length; i++) rows[i].classList.remove('is-open');
        }
    }

    function fillEdit(item) {
        editingKey = item.key;
        el('e-title').textContent = t('编辑备注');
        var bits = [];
        if (item.title) bits.push(item.title);
        if (item.chapter) bits.push(item.chapter);
        if (item.datetime) bits.push(item.datetime);
        el('e-meta').textContent = bits.join(' · ');
        paintQuote(el('e-text'), item);
        el('e-note').value = item.note || '';
        el('e-msg').textContent = '';
        el('e-msg').className = 'notes-msg';
        var rows = document.querySelectorAll('.notes-row');
        for (var i = 0; i < rows.length; i++) {
            rows[i].classList.toggle('is-open', rows[i].dataset.key === item.key);
        }
        setEditOpen(true);
        el('e-note').focus();
    }

    function openEdit(key) {
        jfetch('/api/notes/item?key=' + encodeURIComponent(key)).then(fillEdit).catch(function (err) {
            toast(t('加载失败：%1', err.message || err));
        });
    }

    function closeEdit() {
        setEditOpen(false);
    }

    function saveNote() {
        if (!editingKey) return;
        var body = JSON.stringify({ key: editingKey, note: el('e-note').value });
        jfetch('/api/notes/update', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body })
            .then(function (item) {
                el('e-msg').textContent = t('已保存');
                el('e-msg').className = 'notes-msg';
                if (item && item.key) fillEdit(item);
                el('e-msg').textContent = t('已保存');
                toast(t('已保存'));
                reloadAll();
            })
            .catch(function (err) {
                el('e-msg').textContent = t('保存失败：%1', err.message || err);
                el('e-msg').className = 'notes-msg is-err';
            });
    }

    function confirmDelete(keys) {
        var msg = keys.length === 1 ? t('删除这条高亮或笔记？此操作会同步到已连接的书源。')
            : t('删除所选的 %1 条高亮或笔记？此操作会同步到已连接的书源。', keys.length);
        dialog({ title: t('确认删除'), msg: msg, ok: t('删除'), danger: true }).then(function (ok) {
            if (!ok) return;
            var payload = keys.length === 1 ? { key: keys[0] } : { keys: keys };
            jfetch('/api/notes/remove', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            }).then(function (res) {
                toast(t('已删除 %1 条', res.removed || keys.length));
                keys.forEach(function (k) { delete selected[k]; });
                if (keys.indexOf(editingKey) !== -1) closeEdit();
                reloadAll();
            }).catch(function (err) {
                toast(t('删除失败：%1', err.message || err));
            });
        });
    }

    function scheduleReload() {
        clearTimeout(timer);
        timer = setTimeout(function () {
            bookPage = 1;
            itemPage = 1;
            reloadAll();
        }, 200);
    }

    el('q').addEventListener('input', scheduleReload);
    el('type').addEventListener('change', function () {
        bookPage = 1;
        itemPage = 1;
        reloadAll();
    });
    el('book-prev').addEventListener('click', function () {
        if (bookPage > 1) { bookPage -= 1; reloadAll(); }
    });
    el('book-next').addEventListener('click', function () {
        if (bookPage < bookPages) { bookPage += 1; reloadAll(); }
    });
    el('item-prev').addEventListener('click', function () {
        if (itemPage > 1) { itemPage -= 1; loadItems(); }
    });
    el('item-next').addEventListener('click', function () {
        if (itemPage < itemPages) { itemPage += 1; loadItems(); }
    });
    el('e-save').addEventListener('click', saveNote);
    el('e-cancel').addEventListener('click', closeEdit);
    el('edit-ov').addEventListener('click', function (ev) {
        if (ev.target === el('edit-ov')) closeEdit();
    });
    document.addEventListener('keydown', function (ev) {
        if (ev.key === 'Escape' && !el('edit-ov').hidden) closeEdit();
    });
    el('sel-all').addEventListener('click', function (ev) {
        ev.stopPropagation();
        toggleSelectAll();
    });
    el('b-clear').addEventListener('click', function () { selected = {}; syncBatch(); loadItems(); });
    el('b-delete').addEventListener('click', function () {
        var keys = Object.keys(selected);
        if (keys.length) confirmDelete(keys);
    });

    reloadAll();
})();
