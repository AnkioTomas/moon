(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const retry = document.getElementById('retry');
    let messages, captcha, loading = false, submitting = false, done = false;
    async function request(action, fields = {}) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 90000);
        try {
            const response = await fetch('/api/qidian_verify/' + action, {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ ...fields, ticket }), signal: controller.signal,
            });
            const result = await response.json();
            if (!response.ok) throw new Error(result.error || response.statusText);
            return result;
        } finally { clearTimeout(timer); }
    }
    async function submit(fields) {
        if (submitting || done) return;
        submitting = true;
        status.textContent = messages.pending;
        try {
            await request('verify', fields);
            done = true;
            status.textContent = messages.success;
            document.getElementById('captcha').hidden = true;
            document.getElementById('image-form').hidden = true;
            retry.hidden = true;
        } catch (error) { status.textContent = error.message; }
        finally { submitting = false; }
    }
    function captchaResult(result) {
        if (!result || result.ret !== 0 || result.errorCode || typeof result.ticket !== 'string'
            || !result.ticket || result.ticket.startsWith('trerror_') || typeof result.randstr !== 'string'
            || !result.randstr) {
            status.textContent = messages.failure;
            return;
        }
        return submit({ captcha_ticket: result.ticket, randstr: result.randstr });
    }
    function loadScript() {
        if (typeof window.TencentCaptcha === 'function') return Promise.resolve();
        return new Promise((resolve, reject) => {
            const script = document.createElement('script');
            const timer = setTimeout(() => finish(false), 20000);
            function finish(ok) {
                clearTimeout(timer);
                script.onload = script.onerror = null;
                if (ok) resolve();
                else { script.remove(); reject(new Error(messages.failure)); }
            }
            script.src = 'https://turing.captcha.qcloud.com/TCaptcha.js';
            script.onload = () => finish(typeof window.TencentCaptcha === 'function');
            script.onerror = () => finish(false);
            document.head.appendChild(script);
        });
    }
    async function load(action) {
        if (loading || submitting || done) return;
        loading = true;
        try {
            messages = await request(action);
            document.title = document.getElementById('title').textContent = messages.title;
            document.getElementById('instruction').textContent = messages.instruction;
            retry.textContent = messages.retry;
            document.getElementById('submit').textContent = messages.submit;
            status.textContent = '';
            if (captcha) { captcha.destroy(); captcha = null; }
            const container = document.getElementById('captcha');
            container.innerHTML = '';
            container.hidden = messages.mode !== 'tencent';
            document.getElementById('image-form').hidden = messages.mode !== 'image';
            document.getElementById('code').value = '';
            if (messages.mode === 'image') document.getElementById('image').src = messages.image;
            else {
                await loadScript();
                captcha = new window.TencentCaptcha(container, messages.appid, captchaResult, { type: 'embed' });
                captcha.show();
            }
        } catch (error) { status.textContent = error.message; }
        finally { loading = false; }
    }
    document.getElementById('image-form').onsubmit = event => {
        event.preventDefault();
        return submit({ code: document.getElementById('code').value });
    };
    retry.onclick = () => load('refresh');
    await load('config');
})();
