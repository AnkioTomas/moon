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
            const response = await fetch('/api/changpei_verify/' + action, {
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
        if (captcha) captcha.refresh();
        else loadCaptcha().catch(failed);
    };
    async function verify(token) {
        status.textContent = messages.pending;
        try {
            await request('verify', { token });
            status.textContent = messages.success;
            document.getElementById('captcha-element').hidden = true;
            retry.hidden = true;
        } catch (error) {
            failed(error);
        }
    }
    async function loadCaptcha() {
        if (!window.initAliyunCaptcha) {
            window.AliyunCaptchaConfig = { region: 'cn', prefix: 'euphyd' };
            await new Promise((resolve, reject) => {
                const script = document.createElement('script');
                const timer = setTimeout(() => reject(new Error(messages.load_error)), 20000);
                script.src = 'https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js';
                script.onload = () => { clearTimeout(timer); resolve(); };
                script.onerror = () => { clearTimeout(timer); reject(new Error(messages.load_error)); };
                document.head.appendChild(script);
            });
        }
        window.initAliyunCaptcha({
            SceneId: '1p2ezg9e', mode: 'embed',
            element: '#captcha-element', button: '#captcha-button',
            slideStyle: { width: Math.min(320, document.getElementById('captcha-element').clientWidth), height: 40 },
            getInstance: instance => { captcha = instance; },
            success: verify,
            fail: () => failed(new Error(messages.failure)),
            onError: error => failed(new Error(error.msg || messages.load_error)),
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
