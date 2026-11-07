'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2] + '/book.koplugin/source/kuaikan/web/kuaikan_verify.js', 'utf8');

async function page(options = {}) {
    const nodes = Object.fromEntries(['title', 'instruction', 'status', 'retry', 'captcha']
        .map(id => [id, { textContent: '', hidden: false }]));
    const requests = [], scripts = [];
    let callback, shows = 0;
    const messages = { appid: '2034681882', title: 'Kuaikan', instruction: 'Slide',
        pending: 'Submitting', success: 'Done', failure: 'Failed',
        load_error: 'Load failed', cancelled: 'Cancelled', retry: 'Retry' };
    const context = {
        AbortController, setTimeout, clearTimeout,
        location: { hash: '#fixture' },
        window: {},
        document: {
            get cookie() { throw new Error('Must not read browser credentials'); },
            getElementById: id => nodes[id],
            createElement: () => ({ remove() { this.removed = true; } }),
            head: { appendChild(script) {
                scripts.push(script);
                if (options.blocked) return script.onerror();
                context.window.TencentCaptcha = function(element, appid, cb, opts) {
                    assert.equal(element, nodes.captcha);
                    assert.equal(appid, '2034681882');
                    assert.equal(opts.type, 'embed');
                    callback = cb;
                    this.show = () => { shows++; };
                    this.destroy = () => {};
                };
                script.onload();
            } },
        },
        fetch: async (url, opts) => {
            requests.push({ url, body: JSON.parse(opts.body) });
            return {
                ok: url.endsWith('/config') || !options.rejected,
                json: async () => url.endsWith('/config') ? messages : options.rejected ? { error: 'Rejected' } : { ok: true },
            };
        },
    };
    await vm.runInNewContext(source, context);
    return { nodes, requests, scripts, get callback() { return callback; }, get shows() { return shows; } };
}

(async () => {
    let p = await page();
    assert.equal(p.shows, 1);
    await p.callback({ ret: 2 });
    assert.equal(p.requests.length, 1);
    assert.equal(p.nodes.status.textContent, 'Cancelled');
    await p.callback({ ret: 0, ticket: 'trerror_1001_fixture', randstr: 'random' });
    assert.equal(p.requests.length, 1, 'SDK emergency tickets are never sent');
    await p.callback({ ret: 0, ticket: 'proof', randstr: 'random', errorCode: 1001 });
    assert.equal(p.requests.length, 1);
    await p.callback({ ret: 0, ticket: {}, randstr: 'random' });
    assert.equal(p.requests.length, 1, 'Malformed SDK results do not start a login request');
    await p.callback({ ret: 0, ticket: 'proof', randstr: 'random' });
    assert.deepEqual(p.requests[1].body, { ticket: 'fixture', captcha_ticket: 'proof', randstr: 'random' });
    assert.equal(p.nodes.status.textContent, 'Done');
    assert.equal(p.nodes.captcha.hidden, true);
    await p.callback({ ret: 0, ticket: 'late', randstr: 'random' });
    assert.equal(p.requests.length, 2, 'Success cannot be replayed by a late SDK callback');

    p = await page({ rejected: true });
    await p.callback({ ret: 0, ticket: 'proof', randstr: 'random' });
    assert.equal(p.nodes.status.textContent, 'Rejected');
    assert.equal(p.nodes.retry.hidden, false);
    await p.nodes.retry.onclick();
    assert.equal(p.shows, 2);
    assert.equal(p.requests[2].url, '/api/kuaikan_verify/config');

    const opts = { blocked: true };
    p = await page(opts);
    assert.equal(p.nodes.status.textContent, 'Load failed');
    assert.equal(p.requests.length, 1);
    assert.equal(p.scripts[0].removed, true);
    opts.blocked = false;
    await p.nodes.retry.onclick();
    assert.equal(p.shows, 1);
    console.log('kuaikan web: OK');
})().catch(error => { console.error(error); process.exitCode = 1; });
