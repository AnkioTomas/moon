/* 首页设备状态：低频快照，不持续占用阅读器资源。 */
function refreshStatus() {
    jfetch('/api/status').then(function (status) {
        el('status-battery').textContent = status.battery == null
            ? '无电池信息'
            : (status.charging ? '充电中 · ' : '') + status.battery + '%';
        el('status-storage').textContent = status.storage_available == null
            ? '不可用'
            : fmt(status.storage_available);
        var reading = el('status-reading');
        reading.textContent = status.reading ? (status.book || '正在阅读') : '未在阅读';
        reading.title = reading.textContent;
    }).catch(function () {
        el('status-reading').textContent = '状态不可用';
    }).then(function () {
        setTimeout(refreshStatus, 30000);
    });
}

refreshStatus();
