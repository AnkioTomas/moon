'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(process.argv[2], 'book.koplugin/source/zhihu/web/zhihu_verify.js'), 'utf8');

async function page(options = {}) {
    const nodes = Object.fromEntries(['title', 'instruction', 'status', 'retry', 'captcha-element'].map(id =>
        [id, { textContent: '', hidden: false, replaceChildren() {} }]));
    const requests = [], loaded = [];
    let callback, closed = 0, shown = 0;
    const messages = {
        scripts: options.scripts || ['https://cstaticdun.126.net/load.min.js',
            'https://captcha.zhihu.com/api/v1/captcha/js?sessionId=fixture'],
        title: 'Zhihu', instruction: 'Verify', pending: 'Submitting',
        success: 'Verified', failure: 'Rejected', load_error: 'Load failed', retry: 'Retry',
    };
    const context = {
        AbortController, setTimeout, clearTimeout, URL,
        location: { hash: '#temporary-ticket' },
        document: {
            getElementById: id => nodes[id],
            createElement: () => ({}),
            head: { appendChild(script) { loaded.push(script.src); script.onload(); } },
        },
        fetch: async (url, request) => {
            requests.push({ url, body: JSON.parse(request.body) });
            if (options.offline) throw new Error('offline');
            if (url.endsWith('/config')) return { ok: true, json: async () => messages };
            return { ok: !options.reject, json: async () => options.reject ? { error: 'server rejected' } : { ok: true } };
        },
        window: { ZS_CAP: { init: async config => {
            callback = config.callback;
            return { show() { shown++; }, close() { closed++; } };
        } } },
    };
    await vm.runInNewContext(source, context);
    return { nodes, requests, loaded, callback, closed: () => closed, shown: () => shown };
}

(async () => {
    let p = await page();
    assert.equal(p.shown(), 1);
    assert.equal(p.loaded.length, 2);
    assert.equal(p.nodes.title.textContent, 'Zhihu');
    assert.equal(p.requests[0].url, '/api/zhihu_verify/config');
    assert.equal(p.requests[0].body.ticket, 'temporary-ticket');
    await p.callback({ type: 'vendor', result: { validate: 'user-proof' } });
    assert.equal(p.requests[1].url, '/api/zhihu_verify/verify');
    assert.equal(p.requests[1].body.result, '{"validate":"user-proof"}');
    assert.equal(p.requests[1].body.ticket, 'temporary-ticket');
    assert.equal(p.nodes.status.textContent, 'Verified');
    assert.equal(p.nodes['captcha-element'].hidden, true);
    assert.equal(p.nodes.retry.hidden, true);
    assert.equal(p.closed(), 1);

    p = await page({ reject: true });
    await p.callback({ type: 'vendor', result: { validate: 'bad-proof' } });
    assert.equal(p.nodes.status.textContent, 'server rejected');
    assert.equal(p.nodes.retry.hidden, false);
    await p.nodes.retry.onclick();
    assert.equal(p.requests[2].url, '/api/zhihu_verify/config');
    assert.equal(p.shown(), 2);
    assert.equal(p.closed(), 1);

    p = await page();
    await p.callback(new Error('SDK failed'));
    assert.equal(p.requests.length, 1);
    assert.equal(p.nodes.status.textContent, 'Rejected');

    p = await page({ scripts: ['https://captcha.zhihu.com.evil.test/api/v1/captcha/js?sessionId=x'] });
    assert.equal(p.loaded.length, 0);
    assert.equal(p.nodes.status.textContent, 'Load failed');
    assert.equal(p.shown(), 0);

    p = await page({ offline: true });
    assert.equal(p.nodes.status.textContent, 'offline');
    assert.equal(p.nodes.retry.hidden, false);
    assert.equal(p.shown(), 0);
    console.log('zhihu web: OK');
})().catch(error => { console.error(error); process.exitCode = 1; });
