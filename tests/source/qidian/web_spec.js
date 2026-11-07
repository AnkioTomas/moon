'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2] + '/book.koplugin/source/qidian/web/qidian_verify.js', 'utf8');

async function page(options = {}) {
    const nodes = Object.fromEntries(['title', 'instruction', 'status', 'retry', 'captcha', 'image-form', 'image', 'code', 'submit']
        .map(id => [id, { textContent: '', hidden: false, value: '' }]));
    const requests = [];
    let callback;
    const messages = { mode: options.image ? 'image' : 'tencent', image: 'data:image/png;base64,fixture',
        appid: '1600000770', title: 'Qidian', instruction: 'Verify', pending: 'Pending',
        success: 'Done', failure: 'Failed', retry: 'Refresh', submit: 'Submit' };
    const context = {
        AbortController, setTimeout, clearTimeout, location: { hash: '#fixture' }, window: {},
        document: {
            get cookie() { throw new Error('Must not read browser credentials'); },
            getElementById: id => nodes[id],
            createElement: () => ({ remove() {} }),
            head: { appendChild(script) {
                context.window.TencentCaptcha = function(element, appid, cb, opts) {
                    assert.equal(element, nodes.captcha);
                    assert.equal(appid, '1600000770');
                    assert.equal(opts.type, 'embed');
                    callback = cb;
                    this.destroy = this.show = () => {};
                    if (options.auto) cb({ ret: 0, ticket: 'proof', randstr: 'random' });
                };
                script.onload();
            } },
        },
        fetch: async (url, opts) => {
            requests.push({ url, body: JSON.parse(opts.body) });
            const config = !url.endsWith('/verify');
            return { ok: config || !options.rejected, json: async () =>
                config ? messages : options.rejected ? { error: 'Rejected' } : { ok: true } };
        },
    };
    await vm.runInNewContext(source, context);
    await new Promise(resolve => setImmediate(resolve));
    return { nodes, requests, get callback() { return callback; } };
}

(async () => {
    let p = await page();
    await p.callback({ ret: 2 });
    await p.callback({ ret: 0, ticket: 'trerror_fixture', randstr: 'random' });
    await p.callback({ ret: 0, ticket: 'proof', randstr: 'random', errorCode: 1 });
    assert.equal(p.requests.length, 1, 'Invalid challenges never submit proof');
    await p.callback({ ret: 0, ticket: 'proof', randstr: 'random' });
    assert.deepEqual(p.requests[1].body, { ticket: 'fixture', captcha_ticket: 'proof', randstr: 'random' });
    assert.equal(p.nodes.status.textContent, 'Done');
    await p.callback({ ret: 0, ticket: 'late', randstr: 'random' });
    assert.equal(p.requests.length, 2, 'Completed proof cannot be replayed');
    p = await page({ auto: true });
    assert.equal(p.requests.length, 2, 'Synchronous SDK completion is not lost while loading');
    p = await page({ rejected: true });
    await p.callback({ ret: 0, ticket: 'proof', randstr: 'random' });
    assert.equal(p.nodes.status.textContent, 'Rejected');
    await p.nodes.retry.onclick();
    assert.equal(p.requests[2].url, '/api/qidian_verify/refresh');
    p = await page({ image: true });
    assert.equal(p.nodes.image.src, 'data:image/png;base64,fixture');
    p.nodes.code.value = 'abcd';
    await p.nodes['image-form'].onsubmit({ preventDefault() {} });
    assert.deepEqual(p.requests[1].body, { ticket: 'fixture', code: 'abcd' });
    console.log('qidian web: OK');
})().catch(error => { console.error(error); process.exitCode = 1; });
