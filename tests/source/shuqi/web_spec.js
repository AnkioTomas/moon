'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2] + '/book.koplugin/source/shuqi/web/shuqi_verify.js', 'utf8');

async function page(options = {}) {
    const nodes = Object.fromEntries(['title', 'instruction', 'status', 'retry', 'captcha-element']
        .map(id => [id, { textContent: '', hidden: false }]));
    const requests = [], loaded = [], modules = [], scripts = [], timers = [];
    let captcha;
    const messages = { title: 'Shuqi', pending: 'Sending', success: 'Sent',
        failure: 'Failed', retry: 'Retry', environment_error: 'Environment failed',
        load_error: 'Script may be blocked by an ad blocker; use Cookie sign-in',
        load_timeout: 'Script timeout; may be blocked by an ad blocker; use Cookie sign-in' };
    const fingerprintSDK = function() { this.get = cb => cb(options.fingerprint || 'fingerprint'); };
    const awscSDK = { use(name, cb) {
        modules.push(name);
        if (options.sdkFailed) return cb('failed');
        cb('loaded', name === 'um' ? { init(_opts, done) { done('success', { tn: 'um-token' }); } }
            : { getUA() { return 'wua-proof'; } });
    } };
    const context = {
        AbortController,
        setTimeout: options.timeoutScript ? (fn, ms) => { const timer = { fn, ms }; timers.push(timer); return timer; } : setTimeout,
        clearTimeout: options.timeoutScript ? timer => { timer.cleared = true; } : clearTimeout,
        location: { hash: '#fixture' },
        navigator: { userAgent: 'Test-UA' },
        document: {
            get cookie() { throw new Error('Must not read cookies from the remote-management origin'); },
            getElementById: id => nodes[id], createElement: () => ({ remove() { this.removed = true; } }),
            head: { appendChild(script) {
                loaded.push(script.src);
                scripts.push(script);
                if (options.blockScript && script.src.includes(options.blockScript)) return script.onerror();
                if (options.timeoutScript && script.src.includes(options.timeoutScript)) {
                    queueMicrotask(() => timers.find(timer => timer.ms === 20000 && !timer.cleared).fn());
                    return;
                }
                if (options.slowAwsc && script.src.includes('awsc.js')) {
                    setTimeout(() => {
                        context.window.AWSC = awscSDK;
                        script.onload();
                    }, 10);
                    return;
                }
                if (script.src.includes('fingerprint2.min.js')) context.window.Fingerprint2 = fingerprintSDK;
                if (script.src.includes('awsc.js')) context.window.AWSC = awscSDK;
                if (script.src.includes('AliyunCaptcha.js')) context.window.initAliyunCaptcha = config => { captcha = config; };
                script.onload();
            } },
        },
        window: {
            ...(options.preloaded ? { Fingerprint2: fingerprintSDK, AWSC: awscSDK } : {}),
        },
        fetch: async (url, opts) => {
            requests.push({ url, body: JSON.parse(opts.body) });
            return { ok: !options.rejected || url.endsWith('/config'),
                json: async () => url.endsWith('/config') ? messages : options.rejected ? { error: 'Rejected' } : { ok: true } };
        },
    };
    await vm.runInNewContext(source, context);
    return { nodes, requests, loaded, modules, scripts, get captcha() { return captcha; } };
}

(async () => {
    let p = await page();
    assert.deepEqual(p.modules, ['um', 'uab']);
    assert.equal(p.loaded.length, 3);
    await p.captcha.captchaVerifyCallback('captcha-proof');
    assert.deepEqual(p.requests[1].body, { ticket: 'fixture', captcha: 'captcha-proof',
        fingerprint: 'fingerprint_shuqi_touch', umidtoken: 'um-token', wua: 'wua-proof', user_agent: 'Test-UA' });
    assert.equal(p.nodes.status.textContent, 'Sent');
    assert.equal(p.nodes['captcha-element'].hidden, true);

    p = await page({ sdkFailed: true });
    assert.equal(p.captcha, undefined);
    assert.equal(p.nodes.status.textContent, 'Environment failed');
    assert.equal(p.requests.length, 1);
    assert.equal(p.nodes.retry.hidden, false);

    const blocked = { blockScript: 'fingerprint2.min.js', slowAwsc: true };
    p = await page(blocked);
    assert.match(p.nodes.status.textContent, /may be blocked by an ad blocker/);
    assert.match(p.nodes.status.textContent, /render-resource\.11222\.cn\/third\/fingerprint2\/fingerprint2\.min\.js/);
    assert.equal(p.requests.length, 1, 'No verification request when a script is blocked');
    assert.equal(p.scripts[0].removed, true);
    blocked.blockScript = null;
    await p.nodes.retry.onclick();
    assert.ok(p.captcha, 'Retry can recover after the script is allowed');
    assert.equal(p.loaded.filter(src => src.includes('awsc.js')).length, 1, 'Retry reuses the loaded AWSC SDK');
    await p.captcha.captchaVerifyCallback('captcha-proof');
    assert.equal(p.nodes.status.textContent, 'Sent');

    p = await page({ timeoutScript: 'fingerprint2.min.js' });
    assert.match(p.nodes.status.textContent, /Script timeout/);
    assert.match(p.nodes.status.textContent, /may be blocked by an ad blocker/);
    assert.match(p.nodes.status.textContent, /fingerprint2\.min\.js/);
    assert.equal(p.requests.length, 1);
    assert.equal(p.scripts[0].removed, true);
    assert.equal(p.scripts[0].onload, null, 'Timed-out scripts cannot continue the login pipeline');

    p = await page({ preloaded: true });
    assert.equal(p.loaded.length, 1, 'Already loaded environment SDKs are not fetched again');
    p.captcha.getInstance({ refresh() { throw new Error('Refresh failed'); } });
    await p.nodes.retry.onclick();
    assert.equal(p.nodes.status.textContent, 'Refresh failed');
    assert.equal(p.nodes.retry.hidden, false);

    p = await page({ rejected: true, fingerprint: 'second' });
    await p.captcha.captchaVerifyCallback('captcha-proof');
    assert.equal(p.requests[1].body.fingerprint, 'second_shuqi_touch');
    assert.equal(p.nodes.status.textContent, 'Rejected');
    assert.equal(p.nodes['captcha-element'].hidden, false);
    assert.equal(p.nodes.retry.hidden, false);
    console.log('shuqi web: OK');
})().catch(error => { console.error(error); process.exitCode = 1; });
