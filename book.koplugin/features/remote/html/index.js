/* 首页设备状态：低频快照，不持续占用阅读器资源。 */
function refreshStatus() {
    return jfetch('/api/status').then(function (status) {
        el('status-battery').textContent = status.battery == null
            ? '无电池信息'
            : (status.charging ? '充电中 · ' : '') + status.battery + '%';
        el('status-storage').textContent = status.storage_available == null
            ? '不可用'
            : fmt(status.storage_available);
        var reading = el('status-reading');
        reading.textContent = status.reading ? (status.book || '正在阅读') : '未在阅读';
        reading.title = reading.textContent;
    }).catch(function () {
        el('status-reading').textContent = '状态不可用';
    });
}

pollWhileVisible(refreshStatus, 30000);

/* 备份与恢复：下载整个 .moon（不含日志缓存）；上传备份由设备校验、替换并重启。过程在进度弹窗里，结果写在面板状态行。 */
(function () {
    var input = el('bkfile');
    var pick = el('bkpick');
    var dl = el('bkdl');
    var state = el('bkstate');
    var overlay = el('bkprog');
    var track = overlay.querySelector('.pg-track');
    var cancel = el('pg-cancel');

    function open(title, sub, onCancel) {
        el('pg-title').textContent = title;
        busy(sub);
        cancel.disabled = !onCancel;
        cancel.onclick = function () { cancel.disabled = true; onCancel(); };
        setState(state, '', '');
        overlay.hidden = false;
        overlay.classList.add('on');
    }
    function close() {
        overlay.hidden = true;
        overlay.classList.remove('on');
    }
    // 不定进度：设备在打包 / 恢复，没有可报的百分比
    function busy(sub) {
        el('pg-sub').textContent = sub;
        el('pg-stats').textContent = '';
        el('pg-fill').style.width = '0%';
        track.classList.add('indeterminate');
    }
    function step(sub, done, total) {
        var pct = Math.min(100, Math.floor(done * 100 / total));
        track.classList.remove('indeterminate');
        el('pg-sub').textContent = sub;
        el('pg-fill').style.width = pct + '%';
        el('pg-stats').textContent = pct + '%\u2003' + fmt(done) + ' / ' + fmt(total);
    }

    dl.onclick = function () {
        var ctrl = new AbortController();
        open('正在下载备份', '设备正在打包，数据较多时需要几分钟…', function () { ctrl.abort(); });
        fetch('/api/backup', { signal: ctrl.signal }).then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            var total = Number(res.headers.get('Content-Length')) || 0;
            var name = /filename\*=UTF-8''([^;]+)/.exec(res.headers.get('Content-Disposition') || '');
            var reader = res.body.getReader();
            var chunks = [];
            var got = 0;
            function pump() {
                return reader.read().then(function (r) {
                    if (r.done) return;
                    chunks.push(r.value);
                    got += r.value.length;
                    if (total) step('正在传输', got, total);
                    return pump();
                });
            }
            return pump().then(function () {
                var a = document.createElement('a');
                a.href = URL.createObjectURL(new Blob(chunks, { type: 'application/zip' }));
                a.download = name ? decodeURIComponent(name[1]) : 'moon-backup.zip';
                a.click();
                URL.revokeObjectURL(a.href);
            });
        }).then(function () {
            setState(state, '备份已下载 ✓', 'ok');
        }).catch(function (err) {
            if (err.name === 'AbortError') return setState(state, '已取消下载', '');
            setState(state, t('下载失败：%1', err.message || String(err)), 'err');
        }).then(close);
    };

    pick.onclick = function () { input.click(); };
    input.onchange = function () {
        var file = input.files[0];
        input.value = '';
        if (!file || !window.confirm(t('恢复会覆盖设备上的月读数据，并重启 KOReader，继续吗？'))) return;
        var xhr = new XMLHttpRequest();
        open('正在恢复备份', '正在上传', function () { xhr.abort(); });
        xhr.open('POST', '/api/backup');
        xhr.upload.onprogress = function (e) {
            if (e.lengthComputable) step('正在上传', e.loaded, e.total);
        };
        xhr.upload.onload = function () {
            busy('设备正在校验并恢复，请不要关闭页面…');
            cancel.disabled = true; // 设备已开始替换数据，不可再取消
        };
        xhr.onload = function () {
            var body = {};
            try { body = JSON.parse(xhr.responseText); } catch (e) { /* 非 JSON 响应按状态码报错 */ }
            close();
            if (xhr.status === 200) {
                setState(state, '已恢复 ✓ KOReader 正在重启，稍后可重新连接。', 'ok');
                return;
            }
            setState(state, t('恢复失败：%1', xhr.status === 400 ? t('不是有效的月读备份') : (body.error || 'HTTP ' + xhr.status)), 'err');
        };
        xhr.onabort = function () {
            close();
            setState(state, '已取消恢复', '');
        };
        xhr.onerror = function () {
            close();
            setState(state, '连接中断：设备可能已开始重启，请稍后刷新确认。', 'err');
        };
        xhr.send(file);
    };
})();
