(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const retry = document.getElementById('retry');
    const element = document.getElementById('captcha-element');
    let messages, captcha;
    async function request(action, body) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 45000);
        try {
            const response = await fetch('/api/zhihu_verify/' + action, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ ...body, ticket }),
                signal: controller.signal,
            });
            const result = await response.json();
            if (!response.ok) throw new Error(result.error || response.statusText);
            return result;
        } finally {
            clearTimeout(timer);
        }
    }
    function failed(error) {
        status.textContent = error.message || (messages && messages.failure) || String(error);
        retry.hidden = false;
        if (messages) retry.textContent = messages.retry;
    }
    async function verify(result) {
        if (!result || !result.type || !result.result) {
            failed(new Error(messages.failure));
            return;
        }
        status.textContent = messages.pending;
        try {
            await request('verify', { result: JSON.stringify(result.result) });
            if (captcha) captcha.close();
            element.hidden = true;
            retry.hidden = true;
            status.textContent = messages.success;
        } catch (error) {
            failed(error);
        }
    }
    async function loadCaptcha() {
        retry.hidden = true;
        status.textContent = '';
        if (captcha) { captcha.close(); captcha = null; }
        element.replaceChildren();
        messages = await request('config', {});
        document.title = document.getElementById('title').textContent = messages.title;
        document.getElementById('instruction').textContent = messages.instruction;
        retry.textContent = messages.retry;
        for (const url of messages.scripts) {
            const parsed = new URL(url);
            if (url !== 'https://cstaticdun.126.net/load.min.js'
                && !(parsed.origin === 'https://captcha.zhihu.com' && parsed.pathname === '/api/v1/captcha/js')) {
                throw new Error(messages.load_error);
            }
            await new Promise((resolve, reject) => {
                const script = document.createElement('script');
                const timer = setTimeout(() => reject(new Error(messages.load_error)), 20000);
                script.src = url;
                script.onload = () => { clearTimeout(timer); resolve(); };
                script.onerror = () => { clearTimeout(timer); reject(new Error(messages.load_error)); };
                document.head.appendChild(script);
            });
        }
        captcha = await window.ZS_CAP.init({
            element, callback: verify, enableClose: true,
            onClose: () => { retry.hidden = false; },
        });
        captcha.show();
    }
    retry.onclick = () => loadCaptcha().catch(failed);
    await loadCaptcha().catch(failed);
})();
