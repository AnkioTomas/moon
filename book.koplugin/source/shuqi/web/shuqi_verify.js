(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const retry = document.getElementById('retry');
    let messages, captcha;
    function cookie(name) {
        const matched = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
        return matched ? decodeURIComponent(matched[1]) : '';
    }
    async function request(action, body) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 45000);
        try {
            const response = await fetch('/api/shuqi_verify/' + action, {
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
    function loadScript(src) {
        return new Promise((resolve, reject) => {
            const script = document.createElement('script');
            const timer = setTimeout(() => reject(new Error(messages.load_error)), 20000);
            script.src = src;
            script.onload = () => { clearTimeout(timer); resolve(); };
            script.onerror = () => { clearTimeout(timer); reject(new Error(messages.load_error)); };
            document.head.appendChild(script);
        });
    }
    async function loadCaptcha() {
        if (!window.initAliyunCaptcha) {
            await loadScript('https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js');
        }
        window.initAliyunCaptcha({
            SceneId: '1fujd071',
            prefix: '1ff4ot',
            mode: 'embed',
            element: '#captcha-element',
            immediate: true,
            slideStyle: { width: Math.max(280, window.innerWidth - 40), height: 44 },
            language: 'cn',
            timeout: 2000,
            captchaVerifyCallback: async (captchaVerifyParam) => {
                status.textContent = messages.pending;
                let wua = '';
                try {
                    if (window.uabModule && window.uabModule.getUA) wua = window.uabModule.getUA() || '';
                } catch (error) {
                    wua = '';
                }
                try {
                    await request('verify', {
                        captcha: String(captchaVerifyParam || ''),
                        umidtoken: window.umidToken || '',
                        wua,
                        fingerprint: cookie('shuqi_fingerprint'),
                    });
                    status.textContent = messages.success;
                    document.getElementById('captcha-element').hidden = true;
                    retry.hidden = true;
                    return { captchaResult: true, bizResult: true };
                } catch (error) {
                    failed(error);
                    return { captchaResult: false, bizResult: false };
                }
            },
            onBizResultCallback: () => {},
            getInstance: (instance) => { captcha = instance; },
        });
    }
    retry.onclick = () => {
        retry.hidden = true;
        status.textContent = '';
        document.getElementById('captcha-element').hidden = false;
        if (captcha && captcha.refresh) captcha.refresh();
        else loadCaptcha().catch(failed);
    };
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
