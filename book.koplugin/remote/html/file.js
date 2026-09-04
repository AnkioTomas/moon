/* 文件管理页面逻辑（依赖 /js.js 共享函数与 /api/config） */
loadConfig().then(function (config) {
    var cur = config.home;
    var hist = [];
    var seq = 0;
    var busy = false;
    var parentPath = null;
    var backBtn = el('back');
    var parentBtn = el('parent');
    var refreshBtn = el('refresh');
    var pickFileBtn = el('pickfile');
    var pickFolderBtn = el('pickfolder');
    var mkBtn = el('mk');
    var fileInput = el('file');
    var folderInput = el('folder');
    var explorerContent = document.querySelector('.explorer-content');
    var dropzone = el('dropzone');

    function setBusy(on) {
        busy = on;
        pickFileBtn.disabled = on;
        pickFolderBtn.disabled = on;
        mkBtn.disabled = on;
        refreshBtn.disabled = on;
        fileInput.disabled = on;
        folderInput.disabled = on;
        backBtn.disabled = on || hist.length === 0;
        parentBtn.disabled = on || !parentPath;
        var quick = el('quick');
        var buttons = quick.getElementsByTagName('button');
        for (var i = 0; i < buttons.length; i++) {
            buttons[i].disabled = on;
        }
    }

    function join(dir, name) {
        return (dir === '/' ? '' : dir) + '/' + name;
    }

    function addCell(tr, text, className, label) {
        var td = document.createElement('td');
        if (className) td.className = className;
        if (label) td.setAttribute('data-label', label);
        td.textContent = text;
        tr.appendChild(td);
        return td;
    }

    function render(d) {
        var tb = el('list');
        var entries = Array.isArray(d.entries) ? d.entries : [];
        var count = el('count');
        if (count) count.textContent = entries.length + ' 项';
        tb.innerHTML = '';
        var preview = el('preview');
        preview.innerHTML = '';

        entries.forEach(function (e) {
            var full = join(cur, e.name);
            var tr = document.createElement('tr');
            tr.className = e.dir ? 'd' : 'f';

            if (!e.dir && /\.(png|jpe?g|gif|webp|bmp)$/i.test(e.name)) {
                var img = document.createElement('img');
                img.loading = 'lazy';
                img.alt = e.name;
                img.src = '/download?path=' + encodeURIComponent(full) + '&inline=1';
                preview.appendChild(img);
            }

            var td = document.createElement('td');
            td.className = 'n';
            var a = document.createElement('a');
            a.textContent = e.name + (e.dir ? '/' : '');
            a.title = e.name;
            if (e.dir) {
                a.href = '#';
                a.onclick = function () {
                    if (!busy) load(full);
                    return false;
                };
            } else {
                a.href = '/download?path=' + encodeURIComponent(full);
            }
            td.appendChild(a);
            tr.appendChild(td);

            addCell(tr, e.dir ? '' : fmt(e.size), 'r', '大小');
            addCell(tr, fmtT(e.mtime), 'r', '修改时间');

            var op = document.createElement('td');
            op.className = 'ops r';
            op.setAttribute('data-label', '操作');
            if (!e.protected) {
                if (!e.dir && /\.zip$/i.test(e.name)) {
                    var extract = document.createElement('a');
                    extract.className = 'act';
                    extract.href = '#';
                    extract.textContent = '解压';
                    extract.onclick = function () {
                        if (busy) return false;
                        dialog({
                            title: '解压 ZIP',
                            msg: '解压到同目录下的“' + e.name.slice(0, -4) + '”文件夹？',
                            ok: '解压'
                        }).then(function (yes) {
                            if (!yes) return;
                            setBusy(true);
                            say('正在解压 ' + e.name + '…');
                            jfetch('/api/extract?path=' + encodeURIComponent(full), {
                                method: 'POST'
                            }).then(function (result) {
                                say('已解压到 ' + result.path);
                                setBusy(false);
                                load(cur, true);
                            }).catch(function (err) {
                                say('解压失败: ' + err);
                                setBusy(false);
                            });
                        });
                        return false;
                    };
                    op.appendChild(extract);
                }

                var rn = document.createElement('a');
                rn.className = 'act rn';
                rn.href = '#';
                rn.textContent = '重命名';
                rn.onclick = function () {
                    if (busy) return false;
                    dialog({
                        title: '重命名 / 移动',
                        msg: full,
                        input: full,
                        ok: '保存'
                    }).then(function (to) {
                        if (!to || to === full) return;
                        jfetch(
                            '/api/rename?path=' + encodeURIComponent(full) +
                            '&to=' + encodeURIComponent(to),
                            { method: 'POST' }
                        ).then(function () {
                            load(cur, true);
                        }).catch(function (err) {
                            say('重命名失败: ' + err);
                        });
                    });
                    return false;
                };

                var del = document.createElement('a');
                del.className = 'act';
                del.href = '#';
                del.textContent = '删除';
                del.onclick = function () {
                    if (busy) return false;
                    dialog({
                        title: '删除',
                        msg: '删除 ' + full + ' ？目录将递归删除，不可恢复。',
                        ok: '删除',
                        danger: true
                    }).then(function (yes) {
                        if (!yes) return;
                        jfetch('/api/delete?path=' + encodeURIComponent(full), {
                            method: 'POST'
                        }).then(function () {
                            load(cur, true);
                        }).catch(function (err) {
                            say('删除失败: ' + err);
                        });
                    });
                    return false;
                };
                op.appendChild(rn);
                op.appendChild(del);
            }
            tr.appendChild(op);
            tb.appendChild(tr);
        });

        if (!entries.length) {
            tb.innerHTML = '<tr><td class="empty" colspan="4">空目录</td></tr>';
        }
    }

    function load(p, nohist) {
        if (busy) return;
        var my = ++seq;
        jfetch('/api/list?path=' + encodeURIComponent(p)).then(function (d) {
            if (my !== seq) return; /* 丢弃过期响应 */
            if (!nohist && d.path !== cur) hist.push(cur);
            cur = d.path;
            parentPath = d.parent;
            backBtn.disabled = hist.length === 0;
            parentBtn.disabled = !parentPath;
            el('path').textContent = cur;
            var locations = el('quick').getElementsByTagName('button');
            for (var i = 0; i < locations.length; i++) {
                var root = locations[i].getAttribute('data-path');
                if (locations[i].getAttribute('data-kind') !== 'file') {
                    locations[i].className = cur === root
                        || (root !== '/' && cur.indexOf(root + '/') === 0) ? 'active' : '';
                } else {
                    locations[i].className = '';
                }
            }
            render(d);
        }).catch(function (err) {
            if (my !== seq) return;
            say('列表失败: ' + err);
        });
    }

    backBtn.onclick = function () {
        if (busy || !hist.length) return;
        load(hist.pop(), true);
    };
    parentBtn.onclick = function () {
        if (!busy && parentPath) load(parentPath);
    };
    refreshBtn.onclick = function () {
        if (!busy) load(cur, true);
    };

    function downloadShortcut(s) {
        fetch('/download?path=' + encodeURIComponent(s.path)).then(function (response) {
            if (!response.ok) {
                var err = new Error('HTTP ' + response.status);
                err.status = response.status;
                throw err;
            }
            return response.blob();
        }).then(function (blob) {
            var url = URL.createObjectURL(blob);
            var link = document.createElement('a');
            link.href = url;
            link.download = s.name || s.label;
            document.body.appendChild(link);
            link.click();
            link.remove();
            setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
        }).catch(function (err) {
            dialog({
                title: '日志不可用',
                msg: err.status === 404 ? (s.missing || '文件尚未生成。') : String(err),
                ok: '知道了'
            });
        });
    }

    config.shortcuts.forEach(function (s) {
        var b = document.createElement('button');
        b.type = 'button';
        b.textContent = (s.kind === 'file' ? '▤  ' : '▰  ') + s.label;
        b.setAttribute('data-path', s.path);
        b.setAttribute('data-kind', s.kind || 'directory');
        b.title = s.path;
        b.onclick = function () {
            if (busy) return;
            if (s.kind === 'file') downloadShortcut(s);
            else load(s.path);
        };
        el('quick').appendChild(b);
    });

    function uploadFile(file, dir, name, conflict) {
        return jfetch(
            '/upload?dir=' + encodeURIComponent(dir) +
            '&name=' + encodeURIComponent(name) +
            '&conflict=' + encodeURIComponent(conflict || 'ask'),
            { method: 'PUT', body: file }
        );
    }

    function uploadOne(item) {
        say('上传 ' + item.label + ' (' + fmt(item.file.size) + ')… ');
        return uploadFile(item.file, item.dir, item.name).catch(function (err) {
            if (err.status !== 409) throw err;
            return dialog({
                title: '文件已存在', msg: item.label,
                choices: [
                    { text: '覆盖', value: 'overwrite', kind: 'danger' },
                    { text: '跳过', value: 'skip' },
                    { text: '两者保留', value: 'rename', kind: 'primary' }
                ]
            }).then(function (choice) {
                if (!choice) throw new Error('已取消');
                return uploadFile(item.file, item.dir, item.name, choice);
            });
        });
    }

    function runUploads(items, input) {
        var i = 0;
        (function next() {
            if (i >= items.length) {
                say('全部完成');
                setBusy(false);
                if (input) input.value = '';
                load(cur, true);
                return;
            }
            uploadOne(items[i++]).then(function () {
                el('log').textContent += '成功\n';
                next();
            }).catch(function (err) {
                el('log').textContent += '失败: ' + err + '\n';
                next();
            });
        })();
    }

    pickFileBtn.onclick = function () {
        if (!busy) fileInput.click();
    };
    fileInput.onchange = function () {
        var fs = fileInput.files;
        if (!fs.length || busy) return;
        var items = [];
        for (var i = 0; i < fs.length; i++) {
            items.push({ file: fs[i], dir: cur, name: fs[i].name, label: fs[i].name });
        }
        setBusy(true);
        runUploads(items, fileInput);
    };

    function createDirs(dirs, done) {
        var i = 0;
        (function next() {
            if (i >= dirs.length) { done(); return; }
            var path = dirs[i++];
            jfetch('/api/mkdir?path=' + encodeURIComponent(path), {
                method: 'POST'
            }).catch(function (err) {
                if (err.status !== 409) throw err;
            }).then(next).catch(function (err) {
                say('创建目录失败: ' + path + ': ' + err);
                setBusy(false);
            });
        })();
    }

    pickFolderBtn.onclick = function () {
        if (!busy) folderInput.click();
    };
    function uploadFolderRecords(records, explicitDirs, input) {
        var items = [];
        var seen = {};
        var dirs = [];
        function addDir(rel) {
            var parts = rel.split('/');
            var parent = cur;
            for (var j = 0; j < parts.length; j++) {
                if (!parts[j] || parts[j] === '.' || parts[j] === '..') continue;
                parent = join(parent, parts[j]);
                if (!seen[parent]) {
                    seen[parent] = true;
                    dirs.push(parent);
                }
            }
        }

        for (var d = 0; d < explicitDirs.length; d++) addDir(explicitDirs[d]);
        for (var i = 0; i < records.length; i++) {
            var rel = records[i].relative || records[i].file.name;
            var parts = rel.split('/');
            var name = parts.pop();
            addDir(parts.join('/'));
            var parent = cur;
            for (var j = 0; j < parts.length; j++) {
                if (parts[j] && parts[j] !== '.' && parts[j] !== '..') {
                    parent = join(parent, parts[j]);
                }
            }
            items.push({ file: records[i].file, dir: parent, name: name, label: rel });
        }

        setBusy(true);
        createDirs(dirs, function () {
            runUploads(items, input);
        });
    }

    folderInput.onchange = function () {
        var fs = folderInput.files;
        if (!fs.length || busy) return;
        var records = [];
        for (var i = 0; i < fs.length; i++) {
            records.push({
                file: fs[i],
                relative: fs[i].webkitRelativePath || fs[i].name
            });
        }
        uploadFolderRecords(records, [], folderInput);
    };

    function scanEntry(entry, parent, records, dirs) {
        var relative = parent ? parent + '/' + entry.name : entry.name;
        if (entry.isFile) {
            return new Promise(function (resolve, reject) {
                entry.file(function (file) {
                    records.push({ file: file, relative: relative });
                    resolve();
                }, reject);
            });
        }
        if (!entry.isDirectory) return Promise.resolve();
        dirs.push(relative);
        var reader = entry.createReader();
        return new Promise(function (resolve, reject) {
            function readBatch() {
                reader.readEntries(function (entries) {
                    if (!entries.length) {
                        resolve();
                        return;
                    }
                    Promise.all(entries.map(function (child) {
                        return scanEntry(child, relative, records, dirs);
                    })).then(readBatch, reject);
                }, reject);
            }
            readBatch();
        });
    }

    var dragDepth = 0;
    explorerContent.addEventListener('dragenter', function (event) {
        event.preventDefault();
        if (busy) return;
        dragDepth++;
        dropzone.hidden = false;
    });
    explorerContent.addEventListener('dragover', function (event) {
        event.preventDefault();
        if (event.dataTransfer) event.dataTransfer.dropEffect = busy ? 'none' : 'copy';
    });
    explorerContent.addEventListener('dragleave', function () {
        dragDepth = Math.max(0, dragDepth - 1);
        if (dragDepth === 0) dropzone.hidden = true;
    });
    explorerContent.addEventListener('drop', function (event) {
        event.preventDefault();
        dragDepth = 0;
        dropzone.hidden = true;
        if (busy) return;

        var transfer = event.dataTransfer;
        var records = [];
        var dirs = [];
        var scans = [];
        if (transfer.items) {
            for (var i = 0; i < transfer.items.length; i++) {
                var item = transfer.items[i];
                var getter = item.webkitGetAsEntry || item.getAsEntry;
                var entry = getter && getter.call(item);
                if (entry) scans.push(scanEntry(entry, '', records, dirs));
            }
        }
        if (scans.length) {
            setBusy(true);
            say('正在扫描拖入的文件夹…');
            Promise.all(scans).then(function () {
                setBusy(false);
                uploadFolderRecords(records, dirs, null);
            }).catch(function (err) {
                setBusy(false);
                say('读取拖入内容失败: ' + err);
            });
            return;
        }

        var files = transfer.files;
        if (!files || !files.length) return;
        var items = [];
        for (var j = 0; j < files.length; j++) {
            items.push({ file: files[j], dir: cur, name: files[j].name, label: files[j].name });
        }
        setBusy(true);
        runUploads(items, null);
    });

    mkBtn.onclick = function () {
        if (busy) return;
        dialog({ title: '新建文件夹', input: '', ok: '创建' }).then(function (n) {
            if (!n) return;
            var p = join(cur, n);
            jfetch('/api/mkdir?path=' + encodeURIComponent(p), {
                method: 'POST'
            }).then(function () {
                load(cur, true);
            }).catch(function (err) {
                say('新建失败: ' + err);
            });
        });
    };

    load(cur, true);
}).catch(function (err) {
    el('path').textContent = '配置加载失败: ' + err;
});
