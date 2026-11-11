const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(process.argv[2] + '/book.koplugin/features/notes/web/notes.js', 'utf8');

function node() {
    return {
        value: '', children: [], dataset: {},
        classList: { toggle() {}, remove() {} },
        addEventListener() {},
        appendChild(child) { this.children.push(child); },
        querySelectorAll() { return []; },
        set innerHTML(value) { assert.equal(value, ''); this.children = []; },
    };
}

async function check(books) {
    const nodes = new Map();
    const el = id => {
        if (!nodes.has(id)) nodes.set(id, node());
        return nodes.get(id);
    };
    const calls = [];
    const context = vm.createContext({
        el, t: text => text, setTimeout, clearTimeout,
        document: { addEventListener() {}, createElement: node },
        jfetch: async url => {
            calls.push(url);
            return url.startsWith('/api/notes/books?')
                ? { books, total: Array.isArray(books) ? books.length : 0, page: 1, pages: 1 }
                : { items: {}, total: 0, page: 1, pages: 1 };
        },
    });
    vm.runInContext(source, context);
    await new Promise(setImmediate);
    assert.equal(el('list').children[0].children[0].textContent, '没有符合条件的高亮或笔记。');
    assert.equal(el('sel-all-wrap').hidden, true);
    assert.equal(el('batch').hidden, true);
    assert.equal(el('item-pager').hidden, true);
    if (Array.isArray(books) && books.length) {
        assert.equal(calls.length, 2, 'last note disappeared after the book query');
        assert.equal(el('status').textContent, '没有符合条件的高亮或笔记。');
    } else {
        assert.equal(calls.length, 1);
        assert.equal(el('status').textContent, '请选择左侧的书。');
        assert.equal(el('books').children[0].textContent, '没有符合条件的书籍。');
    }
}

(async () => {
    await check([{ source_id: 'local', stable_id: 'book', title: 'Book', count: 1 }]);
    await check({});
    await check([]);
    console.log('notes web: OK');
})().catch(err => { console.error(err); process.exitCode = 1; });
