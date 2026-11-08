(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const retry = document.getElementById('retry');
    let messages, captcha, loading = true, submitting = false, done = false;
    async function request(action, body) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 90000);
        try {
            const response = await fetch('/api/kuaikan_verify/' + action, {
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
        status.textContent = error.message || messages.failure;
        retry.hidden = false;
    }
    async function submit(result) {
        if (done || submitting) return;
        if (!result || result.ret !== 0 || result.errorCode || typeof result.ticket !== 'string'
            || !result.ticket || typeof result.randstr !== 'string' || !result.randstr
            || result.ticket.startsWith('trerror_')) {
            failed(new Error(result && result.ret === 2 ? messages.cancelled : messages.failure));
            return;
        }
        submitting = true;
        retry.hidden = true;
        status.textContent = messages.pending;
        try {
            await request('verify', { captcha_ticket: result.ticket, randstr: result.randstr });
            done = true;
            status.textContent = messages.success;
            document.getElementById('captcha').hidden = true;
        } catch (error) {
            failed(error);
        } finally {
            submitting = false;
        }
    }
    function loadScript() {
        if (typeof window.TencentCaptcha === 'function') return Promise.resolve();
        return new Promise((resolve, reject) => {
            const script = document.createElement('script');
            const timer = setTimeout(() => finish(messages.load_error), 20000);
            function finish(error) {
                clearTimeout(timer);
                script.onload = script.onerror = null;
                if (error) { script.remove(); reject(new Error(error)); }
                else resolve();
            }
            script.src = 'https://turing.captcha.qcloud.com/TJCaptcha.js';
            script.onload = () => finish(typeof window.TencentCaptcha === 'function' ? null : messages.load_error);
            script.onerror = () => finish(messages.load_error);
            document.head.appendChild(script);
        });
    }
    async function load() {
        await loadScript();
        if (captcha) captcha.destroy();
        document.getElementById('captcha').hidden = false;
        document.getElementById('captcha').innerHTML = '';
        captcha = new window.TencentCaptcha(document.getElementById('captcha'), messages.appid, submit, {
            type: 'embed', userLanguage: 'zh-cn',
        });
        captcha.show();
    }
    retry.onclick = async () => {
        if (done || loading || submitting) return;
        loading = true;
        retry.hidden = true;
        status.textContent = '';
        try { messages = await request('config', {}); await load(); }
        catch (error) { failed(error); }
        finally { loading = false; }
    };
    try {
        messages = await request('config', {});
        document.title = document.getElementById('title').textContent = messages.title;
        document.getElementById('instruction').textContent = messages.instruction;
        retry.textContent = messages.retry;
        await load();
    } catch (error) {
        if (messages) failed(error);
        else status.textContent = error.message;
    } finally {
        loading = false;
    }
})();
