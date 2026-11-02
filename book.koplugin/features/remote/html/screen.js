/* 屏幕镜像：轮询 /api/screen，浏览器按 ETag 复验，画面没变设备回 304。 */
var img = el('scimg');
var state = el('scstate');
var INTERVAL = 200;

function frame() {
    return fetch('/api/screen', { cache: 'no-cache' }).then(function (r) {
        if (r.status === 401) return pair();
        if (r.status === 403) {
            setState(state, t('设备已锁定，暂停投屏'), 'err');
            return null;
        }
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.blob().then(function (blob) {
            var url = URL.createObjectURL(blob);
            img.onload = function () { URL.revokeObjectURL(url); };
            img.src = url;
            setState(state, '', '');
        });
    }).catch(function (e) {
        setState(state, t(e.message || String(e)), 'err');
    });
}

var timer = null;
function loop() {
    timer = null;
    if (document.hidden) return;
    frame().then(function () {
        if (!document.hidden) timer = setTimeout(loop, INTERVAL);
    });
}
document.addEventListener('visibilitychange', function () {
    if (!document.hidden && !timer) loop();
});
loop();

/* 点击 = tap，按住超过 0.5 秒 = hold，位移超过 20 像素 = swipe；坐标换算成设备屏幕像素（图片自然尺寸）。
   图片不可拖拽、touch-action 关掉，否则浏览器会把下拉当成拖图片或页面手势。 */
var start = null;
function devicePoint(e) {
    var box = img.getBoundingClientRect();
    return {
        x: Math.floor((e.clientX - box.left) * img.naturalWidth / box.width),
        y: Math.floor((e.clientY - box.top) * img.naturalHeight / box.height)
    };
}
function sendTouch(query) {
    fetch('/api/screen?' + query, { method: 'POST' }).then(function (r) {
        if (r.status === 401) return pair();
        if (!r.ok) throw new Error('HTTP ' + r.status);
        setTimeout(frame, 400);
    }).catch(function (e) {
        setState(state, t(e.message || String(e)), 'err');
    });
}
img.addEventListener('dragstart', function (e) { e.preventDefault(); });
img.addEventListener('pointerdown', function (e) {
    if (!img.naturalWidth) return;
    img.setPointerCapture(e.pointerId);
    start = { at: Date.now(), p: devicePoint(e) };
});
img.addEventListener('pointerup', function (e) {
    if (!start) return;
    var from = start.p, to = devicePoint(e), held = Date.now() - start.at;
    start = null;
    var dx = to.x - from.x, dy = to.y - from.y;
    var base = 'x=' + from.x + '&y=' + from.y;
    if (Math.max(Math.abs(dx), Math.abs(dy)) > 20) {
        var dir = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'east' : 'west') : (dy > 0 ? 'south' : 'north');
        sendTouch(base + '&kind=swipe&dir=' + dir + '&dist=' + Math.round(Math.max(Math.abs(dx), Math.abs(dy))));
    } else {
        sendTouch(base + '&kind=' + (held > 500 ? 'hold' : 'tap'));
    }
});
img.addEventListener('pointercancel', function () { start = null; });
