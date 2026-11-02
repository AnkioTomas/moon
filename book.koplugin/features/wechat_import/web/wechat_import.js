/* 微信书架分批导入：下载设备落盘的 /shelf/sync 原文 → 浏览器解码 → 切批回传 → 收尾对账。接口 /api/wechat_import/*。 */
(function () {
    var BATCH = 50;
    var MAX_BYTES = 512 * 1024;
    var API = '/api/wechat_import/';
    var LISTS = ['books', 'recentBooks', 'finishReadBooks'];
    var busy = false;

    function post(action, body) {
        return jfetch(API + action, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body || {}),
        });
    }

    function bookId(row) {
        var b = row.book || row.bookInfo || row;
        var id = b.bookId || b.id || b.book_id;
        return id == null ? null : String(id);
    }

    function progress(ratio) {
        el('bar').style.width = Math.round(Math.min(1, Math.max(0, ratio)) * 100) + '%';
    }

    var pinger = null;

    /* 导入期间定时请求设备，让它别自动休眠（休眠会停掉远程管理）。 */
    function setBusy(on) {
        busy = on;
        clearInterval(pinger);
        pinger = on ? setInterval(function () { jfetch(API + 'status', { cache: 'no-store' }).catch(function () {}); }, 15000) : null;
        el('start').disabled = on;
        el('discard').disabled = on;
    }

    /* 流式读：按已收字节更新进度（总量取设备落盘大小），读完再解码。 */
    function download(total) {
        return fetch(API + 'file', { cache: 'no-store' }).then(function (r) {
            if (r.status === 401) return pair().then(function () { return fetch(API + 'file', { cache: 'no-store' }); });
            return r;
        }).then(function (r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            var reader = r.body.getReader();
            var chunks = [], got = 0;
            function pump() {
                return reader.read().then(function (res) {
                    if (res.done) return new Blob(chunks).text();
                    chunks.push(res.value);
                    got += res.value.length;
                    setState(el('info'), t('正在下载 %1 / %2 KB', Math.ceil(got / 1024), Math.ceil(total / 1024)));
                    progress(got / total);
                    return pump();
                });
            }
            return pump();
        }).then(function (text) {
            setState(el('info'), t('正在解析…'));
            return JSON.parse(text);
        });
    }

    function refresh() {
        return jfetch(API + 'status', { cache: 'no-store' }).then(function (s) {
            var has = !!s.size;
            setState(el('info'), has ? t('待导入书架数据 %1 KB', Math.ceil(s.size / 1024))
                : t('设备上没有待导入的书架数据。请先在设备上对微信读书执行一次全量同步（强制刷新书架）。'));
            el('start').disabled = !has;
            el('discard').disabled = !has;
        });
    }

    /* 一批：只带这批书相关的进度与分组，保证请求体远小于设备的 1MB 上限。 */
    function slice(wire, list, rows) {
        var ids = {};
        rows.forEach(function (row) { var id = bookId(row); if (id) ids[id] = true; });
        var batch = { bookProgress: (wire.bookProgress || []).filter(function (p) { return ids[String(p.bookId)]; }) };
        batch[list] = rows;
        batch.archive = (wire.archive || []).map(function (a) {
            return { archiveId: a.archiveId, name: a.name, bookIds: (a.bookIds || []).filter(function (id) { return ids[String(id)]; }) };
        }).filter(function (a) { return a.bookIds.length; });
        return batch;
    }

    /* 请求体超过设备上限会被直接断连（浏览器只看到 Failed to fetch），超了就对半切。 */
    function fit(wire, list, rows, out) {
        var batch = slice(wire, list, rows);
        if (rows.length > 1 && JSON.stringify(batch).length > MAX_BYTES) {
            var half = rows.length >> 1;
            fit(wire, list, rows.slice(0, half), out);
            fit(wire, list, rows.slice(half), out);
        } else {
            out.push(batch);
        }
    }

    function batches(wire) {
        var out = [];
        LISTS.forEach(function (list) {
            var rows = wire[list] || [];
            for (var i = 0; i < rows.length; i += BATCH) fit(wire, list, rows.slice(i, i + BATCH), out);
        });
        for (var j = 0; j < (wire.albums || []).length; j += BATCH) {
            out.push({ albums: wire.albums.slice(j, j + BATCH) });
        }
        return out;
    }

    function run() {
        setBusy(true);
        el('log').textContent = '';
        say('正在下载…');
        progress(0);
        var ids = [];
        var stage = '下载';
        jfetch(API + 'status', { cache: 'no-store' }).then(function (s) {
            return download(s.size);
        }).then(function (wire) {
            var list = batches(wire);
            var chain = Promise.resolve();
            list.forEach(function (batch, i) {
                chain = chain.then(function () {
                    stage = t('第 %1 / %2 批上传', i + 1, list.length);
                    return post('batch', batch).then(function (res) {
                        ids = ids.concat(res.ids);
                        el('info').textContent = t('正在导入 %1 / %2', i + 1, list.length);
                        progress((i + 1) / list.length);
                    });
                });
            });
            return chain.then(function () { stage = '收尾'; return post('commit', { ids: ids, synckey: wire.synckey }); });
        }).then(function (res) {
            var msg = t('导入完成：%1 本，下架 %2 本', ids.length, res.hidden);
            say(msg);
            setState(el('info'), msg, 'ok');
            setBusy(false);
            el('start').disabled = true;
            el('discard').disabled = true;
        }).catch(function (e) {
            var msg = t('导入失败：%1', t(stage) + ' - ' + (e && e.message || e));
            say(msg);
            setState(el('info'), msg, 'err');
            setBusy(false);
        });
    }

    el('start').onclick = run;
    el('discard').onclick = function () {
        if (busy) return;
        post('discard').then(function () { say('已丢弃'); return refresh(); });
    };
    refresh();
})();
