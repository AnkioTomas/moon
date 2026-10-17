/* 浏览器授权登录：发现扩展 → 向设备要 ticket 与任务参数 → 经扩展桥接发起登录。接口 /api/cookie/*。 */
(function () {
    var extReady = false;
    var launching = false;
    var started = false;
    var pending = {};
    var seq = 0;
    var list = el('list');

    function setStatus(state, message) {
        var status = el('ext-state');
        status.dataset.state = state;
        el('ext-state-text').textContent = message;
        el('extension-install').hidden = state !== 'missing';
        updateButtons();
    }

    function setResult(state, message) {
        var result = el('result');
        result.hidden = !message;
        result.dataset.state = state;
        result.textContent = message || '';
    }

    function updateButtons() {
        var disabled = !extReady || launching || started;
        list.querySelectorAll('.cookie-connect').forEach(function (button) {
            button.disabled = disabled;
        });
    }

    function addSource(source) {
        var card = document.createElement('article');
        card.className = 'cookie-source-card';

        var mark = document.createElement('span');
        mark.className = 'cookie-source-mark';
        mark.setAttribute('aria-hidden', 'true');
        mark.textContent = source.name.slice(0, 1);

        var copy = document.createElement('span');
        copy.className = 'cookie-source-copy';
        var name = document.createElement('strong');
        name.textContent = source.name;
        var detail = document.createElement('small');
        detail.textContent = t('网页登录 · 加密同步登录状态');
        copy.appendChild(name);
        copy.appendChild(detail);

        var button = document.createElement('button');
        button.type = 'button';
        button.className = 'cookie-connect';
        button.disabled = !extReady;
        button.textContent = t('继续授权');
        button.addEventListener('click', function () { start(source.id); });

        card.appendChild(mark);
        card.appendChild(copy);
        card.appendChild(button);
        list.appendChild(card);
    }

    function start(id) {
        if (!extReady || launching || started) return;
        launching = true;
        setResult('working', t('正在创建安全授权…'));
        updateButtons();
        jfetch('/api/cookie/ticket', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ source: id }),
        }).then(function (request) {
            var requestId = 'r' + (++seq) + '-' + Date.now();
            pending[requestId] = true;
            window.postMessage({
                type: 'MOON_LOGIN_REQUEST',
                requestId: requestId,
                request: request,
            }, location.origin);
        }).catch(function (error) {
            launching = false;
            setResult('error', t('操作失败：%1', (error && error.message) || String(error)));
            updateButtons();
        });
    }

    window.addEventListener('message', function (event) {
        if (event.source !== window || event.origin !== location.origin || !event.data) return;
        if (event.data.type === 'MOON_EXTENSION_READY') {
            extReady = true;
            setStatus('ready', t('浏览器扩展已就绪'));
            return;
        }
        if (event.data.type !== 'MOON_LOGIN_RESULT' || !pending[event.data.requestId]) return;
        delete pending[event.data.requestId];
        launching = false;
        if (!event.data.ok) {
            setResult('error', t('无法发起登录：%1', event.data.error || ''));
        } else {
            started = true;
            setResult('success', t('授权窗口已打开，请按新页面提示继续。'));
        }
        updateButtons();
    });

    setStatus('checking', t('正在检测浏览器扩展…'));
    setResult('idle', '');
    window.postMessage({ type: 'MOON_EXTENSION_DISCOVER' }, location.origin);
    setTimeout(function () {
        if (!extReady) setStatus('missing', t('没有检测到浏览器扩展，请先安装 moon-cookie-storage 并刷新本页。'));
    }, 1500);

    var loading = document.createElement('div');
    loading.className = 'cookie-list-loading';
    loading.textContent = t('正在读取可用的数据源…');
    list.appendChild(loading);
    jfetch('/api/cookie/sources').then(function (data) {
        list.textContent = '';
        var sources = Array.isArray(data.sources) ? data.sources : [];
        if (!sources.length) {
            var empty = document.createElement('div');
            empty.className = 'cookie-list-empty';
            empty.textContent = t('没有支持浏览器登录的数据源。');
            list.appendChild(empty);
            return;
        }
        sources.forEach(addSource);
        updateButtons();
    }).catch(function (error) {
        list.textContent = '';
        var failed = document.createElement('div');
        failed.className = 'cookie-list-empty is-error';
        failed.textContent = t('读取数据源失败：%1', (error && error.message) || String(error));
        list.appendChild(failed);
    });
})();
