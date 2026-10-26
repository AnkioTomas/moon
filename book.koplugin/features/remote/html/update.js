/* 月读更新：选中或拖入安装包即上传，设备装好后自行重启。 */
var panel = el('uppanel');
var input = el('upfile');
var pick = el('uppick');
var state = el('upstate');
var busy = false;

function install(file) {
    if (busy || !file) return;
    if (!/\.zip$/i.test(file.name)) {
        setState(state, '不是 ZIP 安装包：' + file.name, 'err');
        return;
    }
    busy = true;
    pick.disabled = true;
    setState(state, '正在上传并安装 ' + file.name + '（' + fmt(file.size) + '）…');
    jfetch('/api/update', { method: 'POST', body: file }).then(function () {
        setState(state, '安装完成 ✓ KOReader 正在重启，稍后可重新连接。', 'ok');
    }).catch(function (err) {
        var msg = err.message || String(err);
        if (err.status === 400) msg = '这不是月读插件安装包';
        else if (err.status === 409) msg = '设备正在安装其它更新，请稍后再试';
        setState(state, t('安装失败: %1', t(msg)), 'err');
        busy = false;
        pick.disabled = false;
    });
}

pick.onclick = function () {
    if (!busy) input.click();
};
input.onchange = function () {
    install(input.files[0]);
    input.value = '';
};
panel.addEventListener('dragover', function (event) {
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = busy ? 'none' : 'copy';
});
panel.addEventListener('drop', function (event) {
    event.preventDefault();
    install(event.dataTransfer && event.dataTransfer.files[0]);
});
