/* 浏览器授权登录：发现扩展 → 向设备要 ticket 与任务参数 → 经扩展桥接发起登录。接口 /api/cookie/*。 */
(function () {
    var extReady = false;
    var launching = false;
    var started = false;
    var pending = {};
    var seq = 0;
    var list = el('list');
    var authorizedSources = Object.create(null);
    var sourceUi = Object.create(null);
    var authPoll = null;
    var authPollTimeout = null;

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
            button.disabled = button.dataset.authorized === 'true' || disabled;
        });
    }

    function setAuthorized(id, authorized) {
        authorizedSources[id] = authorized;
        var ui = sourceUi[id];
        if (!ui) return;
        ui.card.classList.toggle('is-authorized', authorized);
        ui.button.dataset.authorized = authorized ? 'true' : 'false';
        ui.button.textContent = authorized ? t('已授权') : t('继续授权');
        updateButtons();
    }

    function stopAuthorizationPoll() {
        if (authPoll) window.clearInterval(authPoll);
        if (authPollTimeout) window.clearTimeout(authPollTimeout);
        authPoll = null;
        authPollTimeout = null;
    }

    function pollAuthorization(id) {
        stopAuthorizationPoll();
        authPoll = window.setInterval(function () {
            jfetch('/api/cookie/sources', { cache: 'no-store' }).then(function (data) {
                var source = (Array.isArray(data.sources) ? data.sources : []).find(function (item) {
                    return item.id === id;
                });
                if (!source || source.authorized !== true) return;
                stopAuthorizationPoll();
                setAuthorized(id, true);
                started = false;
                setResult('success', t('已完成授权'));
                updateButtons();
            }).catch(function (error) {
                setResult('error', t('读取授权状态失败：%1', (error && error.message) || String(error)));
            });
        }, 2000);
        authPollTimeout = window.setTimeout(function () {
            stopAuthorizationPoll();
            started = false;
            setResult('error', t('授权尚未完成，请稍后重试。'));
            updateButtons();
        }, 10 * 60 * 1000);
    }

    function addSource(source) {
        var card = document.createElement('article');
        card.className = 'cookie-source-card';
        var authorized = source.authorized === true;
        if (authorized) card.classList.add('is-authorized');

        var mark = document.createElement('span');
        mark.className = 'cookie-source-mark';
        mark.setAttribute('aria-hidden', 'true');
        if (source.icon) {
            var icon = document.createElement('img');
            icon.className = 'cookie-source-icon';
            icon.src = source.icon;
            icon.alt = '';
            icon.loading = 'lazy';
            icon.referrerPolicy = 'no-referrer';
            icon.addEventListener('error', function () { icon.remove(); });
            mark.appendChild(icon);
        }

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
        button.dataset.authorized = authorized ? 'true' : 'false';
        button.disabled = authorized || !extReady;
        button.textContent = authorized ? t('已授权') : t('继续授权');
        button.addEventListener('click', function () { start(source.id); });

        card.appendChild(mark);
        card.appendChild(copy);
        card.appendChild(button);
        list.appendChild(card);
        sourceUi[source.id] = { card: card, button: button };
        setAuthorized(source.id, authorized);
    }

    function start(id) {
        if (!extReady || launching || started || authorizedSources[id]) return;
        launching = true;
        setResult('working', t('正在创建安全授权…'));
        updateButtons();
        jfetch('/api/cookie/ticket', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ source: id }),
        }).then(function (request) {
            var requestId = 'r' + (++seq) + '-' + Date.now();
            pending[requestId] = id;
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
        var sourceId = pending[event.data.requestId];
        delete pending[event.data.requestId];
        launching = false;
        if (!event.data.ok) {
            setResult('error', t('无法发起登录：%1', event.data.error || ''));
        } else {
            started = true;
            setResult('success', t('授权窗口已打开，请按新页面提示继续。'));
            pollAuthorization(sourceId);
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
    jfetch('/api/cookie/sources', { cache: 'no-store' }).then(function (data) {
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
