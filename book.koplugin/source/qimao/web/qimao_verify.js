(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const retry = document.getElementById('retry');
    let messages, captcha;
    async function request(action, body) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 45000);
        try {
            const response = await fetch('/api/qimao_verify/' + action, {
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
    retry.onclick = () => {
        retry.hidden = true;
        status.textContent = '';
        if (captcha) captcha.reset();
        else loadCaptcha().catch(failed);
    };
    async function verify(result) {
        if (!result.pass || typeof result.rid !== 'string' || !result.rid) {
            failed(new Error(messages.failure));
            return;
        }
        status.textContent = messages.pending;
        try {
            await request('verify', { rid: result.rid });
            status.textContent = messages.success;
            document.getElementById('captcha-element').hidden = true;
            retry.hidden = true;
        } catch (error) {
            failed(error);
        }
    }
    async function loadCaptcha() {
        if (!window.initSMCaptcha) {
            await new Promise((resolve, reject) => {
                const script = document.createElement('script');
                const timer = setTimeout(() => reject(new Error(messages.load_error)), 20000);
                script.src = 'https://castatic.fengkongcloud.cn/pr/v1.0.1/smcp.min.js';
                script.onload = () => { clearTimeout(timer); resolve(); };
                script.onerror = () => { clearTimeout(timer); reject(new Error(messages.load_error)); };
                document.head.appendChild(script);
            });
        }
        window.initSMCaptcha({
            organization: 'KJNSBIdTWSOiYNEsCLS9',
            mode: 'slide', product: 'embed', width: '100%', https: true,
        }, instance => {
            captcha = instance;
            instance.onSuccess(verify);
            instance.onError(() => failed(new Error(messages.load_error)));
            instance.appendTo('captcha-element');
        });
    }
    try {
        messages = await request('config', {});
        document.title = document.getElementById('title').textContent = messages.title;
        document.getElementById('instruction').textContent = messages.instruction;
        retry.textContent = messages.retry;
        await loadCaptcha();
    } catch (error) {
        if (messages) failed(error);
        else status.textContent = error.message;
    }
})();
