(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const retry = document.getElementById('retry');
    let messages, captcha, browser;
    let loading = true;
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
    function loadScript(src, ready) {
        if (ready()) return Promise.resolve();
        return new Promise((resolve, reject) => {
            const script = document.createElement('script');
            const timer = setTimeout(() => finish(messages.load_timeout || messages.load_error), 20000);
            function finish(error) {
                clearTimeout(timer);
                script.onload = script.onerror = null;
                if (error) {
                    script.remove();
                    reject(new Error(error + '\n' + src));
                } else resolve();
            }
            script.src = src;
            script.onload = () => finish(ready() ? null : messages.load_error);
            script.onerror = () => finish(messages.load_error);
            document.head.appendChild(script);
        });
    }
    async function prepareBrowser() {
        const scripts = await Promise.allSettled([
            loadScript('https://render-resource.11222.cn/third/fingerprint2/fingerprint2.min.js',
                () => typeof window.Fingerprint2 === 'function'),
            loadScript('https://g.alicdn.com/AWSC/AWSC/awsc.js', () => typeof window.AWSC?.use === 'function'),
        ]);
        const failedScript = scripts.find(result => result.status === 'rejected');
        if (failedScript) throw failedScript.reason;
        const fingerprint = await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error(messages.environment_error)), 20000);
            new window.Fingerprint2().get((result) => {
                clearTimeout(timer);
                if (!result) reject(new Error(messages.environment_error));
                else resolve(result + '_shuqi_touch');
            });
        });
        function module(name) {
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => reject(new Error(messages.environment_error)), 20000);
                window.AWSC.use(name, (state, sdk) => {
                    clearTimeout(timer);
                    if (state === 'loaded') resolve(sdk);
                    else reject(new Error(messages.environment_error));
                });
            });
        }
        const [um, uab] = await Promise.all([module('um'), module('uab')]);
        const umidtoken = await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error(messages.environment_error)), 20000);
            um.init({ appName: 'wenxue-activity-proxy' }, (state, result) => {
                clearTimeout(timer);
                if (state === 'success' && result && result.tn) resolve(result.tn);
                else reject(new Error(messages.environment_error));
            });
        });
        return { fingerprint, umidtoken, uab };
    }
    async function loadCaptcha() {
        if (!browser) browser = await prepareBrowser();
        await loadScript('https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js',
            () => typeof window.initAliyunCaptcha === 'function');
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
                try {
                    await request('verify', {
                        captcha: String(captchaVerifyParam || ''),
                        umidtoken: browser.umidtoken,
                        wua: browser.uab.getUA(),
                        fingerprint: browser.fingerprint,
                        user_agent: navigator.userAgent,
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
    retry.onclick = async () => {
        if (loading) return;
        retry.hidden = true;
        status.textContent = '';
        document.getElementById('captcha-element').hidden = false;
        loading = true;
        try {
            if (captcha && captcha.refresh) await captcha.refresh();
            else await loadCaptcha();
        } catch (error) {
            failed(error);
        } finally {
            loading = false;
        }
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
    } finally {
        loading = false;
    }
})();
