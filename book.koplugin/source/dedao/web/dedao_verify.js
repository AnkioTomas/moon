(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const retry = document.getElementById('retry');
    let messages, captcha, submitting = false, generation = 0;
    async function request(action, body) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 45000);
        try {
            const response = await fetch('/api/dedao_verify/' + action, {
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
    }
    async function verify(error, result) {
        if (submitting) return;
        if (error || !result || typeof result.validate !== 'string' || !result.validate) {
            failed(new Error(messages.failure));
            return;
        }
        submitting = true;
        retry.hidden = true;
        status.textContent = messages.pending;
        try {
            await request('verify', { validate: result.validate });
            if (captcha) captcha.destroy();
            captcha = null;
            status.textContent = messages.success;
            document.getElementById('captcha-element').hidden = true;
        } catch (reason) {
            failed(reason);
        } finally {
            submitting = false;
        }
    }
    async function loadCaptcha() {
        const current = ++generation;
        retry.hidden = true;
        const config = await request('config', {});
        if (current !== generation) return;
        messages = config;
        document.title = document.getElementById('title').textContent = messages.title;
        document.getElementById('instruction').textContent = messages.instruction;
        retry.textContent = messages.retry;
        status.textContent = '';
        if (captcha) { captcha.destroy(); captcha = null; }
        if (!window.initNECaptcha) {
            await new Promise((resolve, reject) => {
                const script = document.createElement('script');
                const timer = setTimeout(() => reject(new Error(messages.load_error)), 20000);
                script.src = 'https://cstaticdun.126.net/load.min.js';
                script.onload = () => { clearTimeout(timer); resolve(); };
                script.onerror = () => { clearTimeout(timer); reject(new Error(messages.load_error)); };
                document.head.appendChild(script);
            });
        }
        await new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                if (current === generation) generation++;
                reject(new Error(messages.load_error));
            }, 20000);
            window.initNECaptcha({
                captchaId: messages.captcha_id, element: '#captcha-element',
                mode: 'popup', width: '250px', apiVersion: 2,
                onVerify: (error, result) => { if (current === generation) verify(error, result); },
                onClose: () => { if (current === generation && !submitting) retry.hidden = false; },
            }, instance => {
                clearTimeout(timer);
                if (current !== generation) { instance.destroy(); return; }
                captcha = instance;
                instance.verify();
                resolve();
            }, error => {
                clearTimeout(timer);
                reject(new Error(error && error.message || messages.load_error));
            });
        });
    }
    retry.onclick = () => loadCaptcha().catch(failed);
    await loadCaptcha().catch(failed);
})();
