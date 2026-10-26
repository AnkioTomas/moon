const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const root = process.argv[2];
const shared = fs.readFileSync(root + '/book.koplugin/features/remote/html/js.js', 'utf8');

function element(tag, attrs = {}, children = []) {
    const node = {
        nodeType: 1, tagName: tag, children, writes: 0,
        classList: { remove() {} },
        addEventListener() {},
        getAttribute(k) { return attrs[k] || null; },
        setAttribute(k, v) { attrs[k] = v; },
        closest() { return attrs.translate === 'no' ? this : this.parentNode?.closest(); },
        get textContent() { return this.children.map(n => n.nodeValue || '').join(''); },
        set textContent(value) {
            this.writes++;
            this.children = [{ nodeType: 3, nodeValue: value, parentNode: this }];
        },
    };
    children.forEach(child => { child.parentNode = node; });
    return node;
}
function text(value) { return { nodeType: 3, nodeValue: value }; }

async function check(lang) {
    const strings = JSON.parse(execFileSync('luajit', ['-e', `
        local j = dofile("tests/support/json_stub.lua")
        local d = dofile("book.koplugin/l10n/${lang}.lua")
        for k,v in pairs(dofile("book.koplugin/features/remote/l10n/web/${lang}.lua")) do d[k]=v end
        io.write(j.encode(d))
    `], { cwd: root, encoding: 'utf8' }));
    const template = text('解压 保存？');
    const name = text('保存');
    const content = text('保存');
    const textarea = element('TEXTAREA', { placeholder: '查找' }, [content]);
    const keyed = element('BUTTON', { 'data-i18n': '保存' });
    const html = element('HTML', {}, [
        element('P', {}, [template]),
        element('SPAN', { translate: 'no', title: '保存' }, [name]),
        textarea, keyed,
    ]);
    let onReady, onMutation;
    const document = {
        readyState: 'loading', documentElement: html,
        addEventListener(name, fn) { if (name === 'DOMContentLoaded') onReady = fn; },
        getElementById() { return null; },
        querySelector() { return null; },
        createTreeWalker(node) {
            const list = [];
            function collect(n) { (n.children || []).forEach(c => { list.push(c); collect(c); }); }
            collect(node);
            return { nextNode() { return list.shift(); } };
        },
    };
    const context = vm.createContext({
        document, window: {}, localStorage: { setItem() {} },
        XMLHttpRequest: class {
            open() {}
            send() { this.status = 200; this.responseText = JSON.stringify({ lang, strings }); }
        },
        MutationObserver: class {
            constructor(fn) { onMutation = fn; }
            observe() {}
        },
        fetch: async () => ({ ok: true, text: async () => '[]' }),
    });
    vm.runInContext(shared, context);
    const i18n = context.I18N;
    const expected = (key, ...args) => strings[key].replace(/%(\d)/g, (_, n) => args[n - 1]);
    assert.equal(i18n.tr('解压 保存？'), expected('解压 %1？', '保存'));
    assert.equal(i18n.tr('上传到 /3 项'), expected('上传到 %1', '/3 项'));
    assert.equal(i18n.tr('已复制路径 /保存'), expected('已复制路径 %1', '/保存'));
    assert.equal(i18n.t('解压 %1？', '$&保存'), expected('解压 %1？', '$&保存'));
    assert.equal(i18n.t('更多页面'), lang === 'en' ? 'More pages' : '更多頁面');
    onReady();
    assert.equal(template.nodeValue, expected('解压 %1？', '保存'));
    assert.equal(name.nodeValue, '保存');
    assert.equal(name.parentNode.getAttribute('title'), '保存');
    assert.equal(content.nodeValue, '保存');
    assert.equal(textarea.getAttribute('placeholder'), strings['查找']);
    onMutation([{ type: 'childList', addedNodes: [textarea, keyed] }]);
    onMutation([{ type: 'characterData', target: content }]);
    assert.equal(content.nodeValue, '保存');
    assert.equal(keyed.writes, 1, 'data-i18n must not keep rewriting its own mutations');
    const dynamic = element('P', {}, [text('解压 保存？')]);
    onMutation([{ type: 'childList', addedNodes: [dynamic] }]);
    assert.equal(dynamic.textContent, expected('解压 %1？', '保存'));
    await Promise.resolve();
    context.fetch = async () => ({
        ok: false, status: 400,
        text: async () => JSON.stringify({ error: '设备上没有激活的输入框' }),
    });
    await assert.rejects(context.jfetch('/api/input'), err =>
        err.status === 400 && err.message === strings['设备上没有激活的输入框']);

    const nodes = {};
    document.getElementById = id => nodes[id] ||= element('DIV');
    document.getElementById('bkprog').querySelector = () => null;
    context.pollWhileVisible = () => {};
    vm.runInContext(fs.readFileSync(root + '/book.koplugin/features/remote/html/index.js', 'utf8'), context);
    context.fetch = async () => ({
        ok: true, text: async () => JSON.stringify({ reading: true, book: '保存' }),
    });
    await context.refreshStatus();
    onMutation([{ type: 'childList', addedNodes: [nodes['status-reading']] }]);
    assert.equal(nodes['status-reading'].textContent, '保存', 'book titles are not UI strings');
    context.fetch = async () => ({ ok: true, text: async () => '{"reading":false}' });
    await context.refreshStatus();
    assert.equal(nodes['status-reading'].textContent, strings['未在阅读']);
    context.fetch = async () => { throw new Error('offline'); };
    await context.refreshStatus();
    assert.equal(nodes['status-reading'].textContent, strings['状态不可用']);
    vm.runInContext(fs.readFileSync(root + '/book.koplugin/features/remote/html/update.js', 'utf8'), context);
    for (const [status, key] of [
        [400, '这不是月读插件安装包'],
        [409, '设备正在安装其它更新，请稍后再试'],
    ]) {
        context.jfetch = () => Promise.reject(Object.assign(new Error('server error'), { status }));
        context.install({ name: 'book.zip', size: 100 });
        await new Promise(setImmediate);
        assert.equal(nodes.upstate.textContent, expected('安装失败: %1', strings[key]));
    }
}

(async () => {
    await check('en');
    await check('zh_TW');
    console.log('remote web: OK');
})().catch(err => { console.error(err); process.exitCode = 1; });
