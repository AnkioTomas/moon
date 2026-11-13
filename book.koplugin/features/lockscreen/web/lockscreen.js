(function () {
    function toast(msg) {
        var box = el('toasts');
        if (!box) return;
        var n = document.createElement('div');
        n.className = 'sub-toast';
        n.textContent = msg;
        box.appendChild(n);
        setTimeout(function () { n.remove(); }, 2800);
    }

    // 文件名即时间戳：20240102-030405(-2).png
    function stamp(name) {
        var m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/.exec(name || '');
        if (!m) return name || '';
        return m[1] + '-' + m[2] + '-' + m[3] + ' ' + m[4] + ':' + m[5] + ':' + m[6];
    }

    function sizeText(bytes) {
        bytes = Number(bytes) || 0;
        if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
        return Math.max(1, Math.round(bytes / 1024)) + ' KB';
    }

    function downloadUrl(path, inline) {
        return '/download?path=' + encodeURIComponent(path) + (inline ? '&inline=1' : '');
    }

    function card(item) {
        var node = document.createElement('div');
        node.className = 'lockscreen-card';

        var img = document.createElement('img');
        img.loading = 'lazy';
        img.alt = item.name || '';
        img.src = downloadUrl(item.path, true);
        img.addEventListener('error', function () {
            img.removeAttribute('src');
            img.alt = t('图片加载失败');
        });

        var meta = document.createElement('div');
        meta.className = 'lockscreen-meta';
        // 文件名与大小是用户数据，不参与翻译
        meta.setAttribute('translate', 'no');

        var time = document.createElement('span');
        time.className = 'lockscreen-time';
        time.textContent = stamp(item.name);

        var size = document.createElement('span');
        size.className = 'lockscreen-size';
        size.textContent = sizeText(item.size);

        var link = document.createElement('a');
        link.className = 'file-action';
        link.href = downloadUrl(item.path, false);
        link.setAttribute('download', item.name || '');
        link.textContent = t('下载');

        meta.appendChild(time);
        meta.appendChild(size);
        meta.appendChild(link);
        node.appendChild(img);
        node.appendChild(meta);
        return node;
    }

    function empty(text) {
        var node = document.createElement('div');
        node.className = 'lockscreen-empty';
        var strong = document.createElement('strong');
        strong.textContent = text;
        node.appendChild(strong);
        return node;
    }

    function render(items) {
        var grid = el('grid');
        grid.textContent = '';
        if (!items.length) {
            el('status').textContent = t('还没有历史壁纸');
            grid.appendChild(empty(t('还没有历史壁纸')));
            return;
        }
        el('status').textContent = t('共 %1 张', items.length);
        items.forEach(function (item) { grid.appendChild(card(item)); });
    }

    // jfetch 而不是 fetch：未配对时由 js.js 弹「请在 Kindle 上点允许」并重试；
    // 配对完成的 Cookie 之后由 <img>/<a> 的 /download 直接带上。
    function load() {
        jfetch('/api/lockscreen/list').then(function (data) {
            render((data && data.items) || []);
        }).catch(function (err) {
            var detail = (err && (err.message || err)) || '';
            var text = detail ? t('加载失败：%1', detail) : t('加载失败');
            el('status').textContent = t('加载失败');
            el('grid').textContent = '';
            el('grid').appendChild(empty(text));
            toast(text);
        });
    }

    load();
})();
