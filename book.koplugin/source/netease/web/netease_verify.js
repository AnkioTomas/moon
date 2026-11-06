(async function () {
    'use strict';
    const ticket = location.hash.slice(1);
    const status = document.getElementById('status');
    const send = document.getElementById('send');
    const code = document.getElementById('code');
    async function request(action, body) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 45000);
        try {
            const response = await fetch('/api/netease_verify/' + action, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(Object.assign({ ticket: ticket }, body || {})),
                signal: controller.signal,
            });
            const result = await response.json();
            if (!response.ok) throw new Error(result.error || response.statusText);
            return result;
        } finally {
            clearTimeout(timer);
        }
    }
    let messages;
    try {
        messages = await request('config');
    } catch (error) {
        status.textContent = error.message || 'failed';
        return;
    }
    document.getElementById('title').textContent = messages.title || '';
    document.getElementById('instruction').textContent = messages.instruction || '';
    document.getElementById('captcha').src = 'data:' + messages.mime + ';base64,' + messages.image;
    document.getElementById('captcha').alt = messages.instruction || '';
    send.textContent = messages.button || '';
    send.addEventListener('click', async function () {
        send.disabled = true;
        status.textContent = messages.pending || '';
        try {
            await request('verify', { code: code.value.trim() });
            status.textContent = messages.success || '';
            send.hidden = true;
            code.disabled = true;
        } catch (error) {
            status.textContent = error.message || messages.pending;
            send.disabled = false;
        }
    });
})();
